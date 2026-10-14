# Durable, editable capture drafts. Only review_commit! allocates archive IDs.
mutable struct ReviewEntry
    id::Int
    source::String
    output::String
    corners::Union{Nothing,NTuple{4,Vec2f}}
    rotation::Union{Nothing,Int}
    detected_rotation::Int
    side::Symbol
    starts::Bool
    included::Bool
    manual_include::Bool
    revision::Int
    status::Symbol
    error::String
    words::Vector{Word}
    blank::Bool
end

mutable struct ReviewSession
    dir::String
    entries::Vector{ReviewEntry}
    history::Vector{Vector{ReviewEntry}}
    nextid::Int
    duplex::Bool
    dpi::Int
    jobs::Channel{Any}
    worker::Task
    lock::ReentrantLock
    version::Int
    processor::Any
    committed::Dict{Int,Int}
    commit_started::Bool
    capture_buffers::Channel{Any}
    owns_ocr::Bool
end

mutable struct ReviewCapture
    pixels::Any
    pool::Channel{Any}
    writer::Union{Nothing,Task}
end
ReviewCapture(pixels,pool)=ReviewCapture(pixels,pool,nothing)

# GUI errors need the cause, not a symbolized worker backtrace. Symbolizing an
# OOM backtrace can itself exhaust native memory while reading debug symbols.
review_error(err)=sprint(showerror,err)
review_error(err::CapturedException)=review_error(err.ex)
review_error(err::TaskFailedException)=join((review_error(e.exception) for e in Base.current_exceptions(err.task)),"; ")
review_error(::OutOfMemoryError)="Speichergrenze erreicht. Verarbeitung fehlgeschlagen; gespeicherte Originale bleiben erhalten."

entry_copy(e::ReviewEntry) = ReviewEntry((getfield(e,f) for f in fieldnames(ReviewEntry))...)
function review_record(e::ReviewEntry)
    Dict("id"=>e.id,"source"=>e.source,"output"=>e.output,
        "corners"=>(e.corners===nothing ? nothing : Tuple.(e.corners)),
        "rotation"=>e.rotation,"detected_rotation"=>e.detected_rotation,
        "side"=>String(e.side),"starts"=>e.starts,"included"=>e.included,
        "manual_include"=>e.manual_include,"revision"=>e.revision,"status"=>String(e.status),"error"=>e.error,
        "words"=>e.words,"blank"=>e.blank)
end

function review_save!(s::ReviewSession)
    atomic_json(joinpath(s.dir,"draft.json"),Dict("version"=>1,"nextid"=>s.nextid,"duplex"=>s.duplex,"dpi"=>s.dpi,
        "commit_started"=>s.commit_started,"committed"=>Dict(string(k)=>v for (k,v) in s.committed),
        "entries"=>review_record.(s.entries)))
    s.version += 1
end

struct ReviewProcessor{O,D}
    ocr::O
    dpi::Int
    dewarper::D
    outputs::Channel{Any}
end
function ReviewProcessor(ocr,dpi,dewarper;workers=2)
    slots=Channel{Any}(workers)
    for _ in 1:workers;put!(slots,Ref{Any}(nothing));end
    ReviewProcessor(ocr,dpi,dewarper,slots)
end
function (p::ReviewProcessor)(source,corners,rotation,output;kw...)
    buffer=take!(p.outputs)
    try
        review_prepare(source,corners,rotation,output;ocr=p.ocr,dpi=p.dpi,dewarper=p.dewarper,output_buffer=buffer,kw...)
    finally
        put!(p.outputs,buffer)
    end
end

function review_prepare(source,corners,rotation,output;ocr,dpi,dewarper,image_saved=()->nothing,output_buffer=nothing)
    ocr isa ProcessOCR && return process_review(source,corners,rotation,output;ocr,dpi,dewarper,image_saved)
    image = source isa AbstractMatrix ? source : review_load_image(source)
    saving=Ref{Union{Nothing,Task}}(nothing)
    function image_ready(processed)
        saving[]=Threads.@spawn begin
            tmp=output*".tmp.png"
            review_save_image(tmp,processed)
            mv(tmp,output;force=true)
            image_saved()
        end
    end
    result=try
        prepare_page_image(image;ocr,dpi,dewarper,rotation,image_ready,corners,output_buffer)
    finally
        saving[]===nothing || fetch(saving[])
    end
    return (words=result.words,blank=result.blank,rotation=result.rotation)
end

"""
    ReviewSession(dir; duplex=true, dpi=300, ocr=default_ocr(), dewarper=nothing, workers=2)

Persistent editable scan draft. Reopen the same directory to recover captures
and corrections. Front/back pairs are captured consecutively; each front starts
one document initially. Use `review_edit!(s,id;starts=false)` to join documents.
Closing drains OCR jobs; it does not archive or delete the draft.
At most `workers` pages are prepared concurrently; the GPU engine serializes
its own model buffers. Fresh captures use their retained pixels, with original
PNG persistence alongside processing and corrected image saving alongside OCR.
"""
function ReviewSession(dir::AbstractString;duplex::Bool=true,dpi::Int=300,ocr=nothing,dewarper=nothing,processor=nothing,workers::Int=2)
    workers>0 || throw(ArgumentError("workers must be positive"))
    dir=abspath(dir); mkpath(dir)
    for name in ("raw","processed") mkpath(joinpath(dir,name)) end
    entries=ReviewEntry[]; nextid=1; committed=Dict{Int,Int}(); started=false
    file=joinpath(dir,"draft.json")
    if isfile(file)
        data=JSON3.read(read(file,String),Dict{String,Any})
        data["version"]==1 || throw(ArgumentError("unsupported draft version"))
        duplex,dpi,nextid=Bool(data["duplex"]),Int(data["dpi"]),Int(data["nextid"])
        committed=Dict(parse(Int,k)=>Int(v) for (k,v) in data["committed"])
        started=get(data,"commit_started",false)
        for r in data["entries"]
            corners=r["corners"] === nothing ? nothing : Tuple(Vec2f.(r["corners"]))
            words=[Word((w[string(f)] for f in fieldnames(Word))...) for w in r["words"]]
            status=Symbol(r["status"])
            status == :ready && !isfile(r["output"]) && (status=:queued)
            push!(entries,ReviewEntry(r["id"],r["source"],r["output"],corners,r["rotation"],r["detected_rotation"],
                Symbol(r["side"]),r["starts"],r["included"],r["manual_include"],r["revision"],status,r["error"],words,r["blank"]))
        end
    end
    owns_ocr=processor===nothing && ocr===nothing
    if processor === nothing
        ocr === nothing && (ocr=default_ocr())
        processor=ReviewProcessor(ocr,dpi,dewarper;workers)
    end
    jobs=Channel{Any}(Inf)
    buffers=Channel{Any}(4)
    for _ in 1:4;put!(buffers,nothing);end
    s=ReviewSession(dir,entries,Vector{ReviewEntry}[],nextid,duplex,dpi,jobs,Task(()->nothing),ReentrantLock(),0,processor,committed,started,buffers,owns_ocr)
    function process_job(job)
        id,rev,img,source,foreground,processing_pid,capture=job
        try
            # Persist originals even if an edit has already superseded this
            # processing job. Undo and replacement recovery still need them.
            pixels=if img isa Task
                fetch(img)
            elseif img !== nothing
                fetch(Threads.@spawn begin
                    tmp=source*".tmp.png"
                    review_save_image(tmp,img); mv(tmp,source;force=true)
                end)
                img
            else
                nothing
            end
            entry=lock(s.lock) do
                i=findfirst(e->e.id==id,s.entries)
                i === nothing && return nothing
                e=s.entries[i]
                e.revision==rev || return nothing
                e.status=:processing; review_save!(s)
                entry_copy(e)
            end
            entry === nothing && return
            result=fetch(Threads.@spawn begin
                input=s.processor isa ReviewProcessor && !(s.processor.ocr isa ProcessOCR) && pixels isa AbstractMatrix ? pixels : entry.source
                if s.processor isa ReviewProcessor
                    s.processor(input,entry.corners,entry.rotation,entry.output;image_saved=()->lock(s.lock) do
                        s.version+=1
                    end)
                else
                    s.processor(input,entry.corners,entry.rotation,entry.output)
                end
            end)
            lock(s.lock) do
                i=findfirst(e->e.id==id,s.entries)
                i === nothing && return
                e=s.entries[i]
                e.revision==rev || return
                e.words=result.words; e.blank=result.blank; e.detected_rotation=result.rotation
                e.manual_include || (e.included=!result.blank)
                e.status=:ready; e.error=""; review_save!(s)
            end
        catch err
            lock(s.lock) do
                i=findfirst(e->e.id==id,s.entries)
                if i !== nothing && s.entries[i].revision==rev
                    e=s.entries[i]; e.status=:error; e.error=review_error(err); review_save!(s)
                end
            end
        finally
            foreground && Threads.atomic_sub!(OCR_PENDING,1)
            process_ocr_activity(processing_pid,-1)
            capture===nothing || put!(capture.pool,capture.pixels)
        end
    end
    s.worker=@async begin
        active=Task[]
        slots=Base.Semaphore(workers)
        try
            for job in jobs
                if job isa Channel
                    foreach(wait,active);empty!(active)
                    put!(job,nothing)
                else
                    filter!(!istaskdone,active)
                    Base.acquire(slots)
                    push!(active,@async try
                        process_job(job)
                    finally
                        Base.release(slots)
                    end)
                end
            end
        finally
            foreach(wait,active)
        end
    end
    errormonitor(s.worker)
    for e in entries
        if e.status in (:queued,:processing)
            review_enqueue!(s,(e.id,e.revision,nothing,e.source))
        end
    end
    review_save!(s)
    return s
end

function review_enqueue!(s,job)
    foreground=s.processor isa ReviewProcessor && s.processor.ocr isa Union{PaddleOCR,ProcessOCR}
    processing_pid=foreground ? (s.processor.ocr isa ProcessOCR ? s.processor.ocr.pid : PROCESS_PID[]) : 0
    foreground && Threads.atomic_add!(OCR_PENDING,1)
    process_ocr_activity(processing_pid,1)
    try
        capture=length(job)==5 ? job[5] : nothing
        put!(s.jobs,(job[1:4]...,foreground,processing_pid,capture))
    catch
        foreground && Threads.atomic_sub!(OCR_PENDING,1)
        process_ocr_activity(processing_pid,-1)
        rethrow()
    end
end

function review_mutable(s)
    isopen(s.jobs) || throw(ArgumentError("Entwurf ist geschlossen"))
    s.commit_started && throw(ArgumentError("Archivierung wurde begonnen; zum Fortsetzen erneut archivieren"))
end
function review_snapshot!(s)
    push!(s.history,entry_copy.(s.entries))
    length(s.history)>20 && popfirst!(s.history)
end
function review_entry(s,id)
    i=findfirst(e->e.id==id,s.entries)
    i === nothing && throw(ArgumentError("Aufnahme $id nicht gefunden"))
    return s.entries[i]
end
function review_queue!(s,e,img=nothing)
    capture=img isa ReviewCapture ? img : nothing
    capture===nothing || (img=capture.pixels)
    e.revision+=1; e.status=:queued; e.error=""
    e.output=joinpath(s.dir,"processed","$(e.id)_$(e.revision).png")
    if img !== nothing
        # Make the original available for review immediately, even while an
        # earlier page occupies the OCR worker. The worker awaits persistence
        # before processing, and close(s) drains both operations.
        input,source=img,e.source
        retain_pixels=!(s.processor isa ReviewProcessor && s.processor.ocr isa ProcessOCR)
        img=Threads.@spawn begin
            if retain_pixels
                tmp=source*".tmp.png"
                review_save_image(tmp,input); mv(tmp,source;force=true)
            else
                try
                    Distributed.remotecall_fetch(worker_save_capture,s.processor.ocr.pid,source,input)
                catch
                    # A crashed processing process must not lose the captured
                    # original. Persist locally, then report the worker error.
                    tmp=source*".tmp.png"
                    review_save_image(tmp,input);mv(tmp,source;force=true)
                    rethrow()
                end
            end
            lock(s.lock) do
                s.version+=1
            end
            retain_pixels ? input : nothing
        end
    end
    capture===nothing || (capture.writer=img isa Task ? img : nothing)
    review_enqueue!(s,(e.id,e.revision,img,e.source,capture))
end

"""Add an image (x first), replace a capture, or insert before a capture. Originals are retained."""
function review_add!(s::ReviewSession,img::AbstractMatrix;corners=nothing,replace_id=nothing,before_id=nothing)
    review_mutable(s)
    buffer=take!(s.capture_buffers)
    queued=false
    capture=nothing
    try
      if buffer===nothing || size(buffer)!=size(img) || eltype(buffer)!=eltype(img)
          buffer=similar(img)
      end
      copyto!(buffer,img)
      capture=ReviewCapture(buffer,s.capture_buffers)
      lock(s.lock) do
        review_mutable(s); review_snapshot!(s)
        n=s.nextid; s.nextid+=1
        source=joinpath(s.dir,"raw",lpad(string(n),6,'0')*".png")
        if replace_id !== nothing
            e=review_entry(s,replace_id)
            e.source=source; e.corners=corners; e.rotation=nothing
            e.words=Word[]; e.blank=false; e.manual_include=false; e.included=true
        else
            index=before_id === nothing ? length(s.entries)+1 : findfirst(e->e.id==before_id,s.entries)
            index === nothing && throw(ArgumentError("Aufnahme nicht gefunden"))
            side=!s.duplex ? :single : (index==1 || s.entries[index-1].side != :front ? :front : :back)
            e=ReviewEntry(n,source,"",corners,nothing,0,side,side!=:back,true,false,0,:queued,"",Word[],false)
            insert!(s.entries,index,e)
        end
        review_queue!(s,e,capture);queued=true;review_save!(s)
        return e.id
      end
    finally
        if !queued
            # The writer may already have started when enqueue fails. Await it
            # outside s.lock before allowing the next capture to reuse pixels.
            if capture!==nothing && capture.writer!==nothing
                try wait(capture.writer) catch end
            end
            lock(s.lock) do
                isopen(s.capture_buffers) && put!(s.capture_buffers,buffer)
            end
        end
    end
end

function review_edit!(s::ReviewSession,id;rotation=nothing,corners=nothing,included=nothing,starts=nothing,side=nothing,retry=false)
    lock(s.lock) do
        review_mutable(s)
        side === nothing || side in (:front,:back,:single) || throw(ArgumentError("invalid side"))
        rotation === nothing || mod(rotation,90)==0 || throw(ArgumentError("rotation must be a multiple of 90"))
        e=review_entry(s,id); review_snapshot!(s)
        if rotation !== nothing e.rotation=mod(rotation,360) end
        if corners !== nothing e.corners=corners end
        if included !== nothing e.included=included; e.manual_include=true end
        if starts !== nothing e.starts=starts end
        if side !== nothing e.side=side end
        if rotation !== nothing || corners !== nothing || retry
            review_queue!(s,e)
        end
        review_save!(s)
    end
end

function review_validate_corners(corners,dims)
    length(corners)==4 || throw(ArgumentError("Vier Ecken erforderlich"))
    w,h=dims
    all(p->all(isfinite,p) && 0.5<=p[1]<=w+0.5 && 0.5<=p[2]<=h+0.5,corners) ||
        throw(ArgumentError("Ecken müssen im Bild liegen"))
    cross(a,b)=a[1]*b[2]-a[2]*b[1]
    all(i->cross(corners[mod1(i+1,4)]-corners[i],corners[mod1(i+2,4)]-corners[mod1(i+1,4)])>0,1:4) ||
        throw(ArgumentError("Ecken im Uhrzeigersinn wählen: oben links, oben rechts, unten rechts, unten links"))
    area=abs(sum(cross(corners[i],corners[mod1(i+1,4)]) for i in 1:4))/2
    area>0.01w*h || throw(ArgumentError("Zuschnitt ist zu klein"))
    return corners
end

function review_word!(s::ReviewSession,id,index::Int,value::AbstractString)
    lock(s.lock) do
        review_mutable(s);e=review_entry(s,id)
        e.status==:ready || throw(ArgumentError("OCR läuft noch"))
        1<=index<=length(e.words) || throw(ArgumentError("Wort nicht gefunden"))
        isempty(strip(value)) && throw(ArgumentError("Wort darf nicht leer sein"))
        review_snapshot!(s);e.words=copy(e.words);w=e.words[index]
        e.words[index]=Word(String(value),w.x,w.y,w.width,w.height,w.line_y,w.line_height,100f0)
        review_save!(s)
    end
end

function review_delete!(s::ReviewSession,id)
    lock(s.lock) do
        review_mutable(s); review_entry(s,id); review_snapshot!(s)
        filter!(e->e.id!=id,s.entries); review_save!(s)
    end
end
function review_move!(s::ReviewSession,id,delta::Int)
    lock(s.lock) do
        review_mutable(s); e=review_entry(s,id)
        i=findfirst(==(e),s.entries); j=clamp(i+delta,1,length(s.entries))
        i==j && return
        review_snapshot!(s); deleteat!(s.entries,i); insert!(s.entries,j,e); review_save!(s)
    end
end
function review_undo!(s::ReviewSession)
    lock(s.lock) do
        review_mutable(s); isempty(s.history) && return false
        old=pop!(s.history)
        revisions=Dict(e.id=>e.revision for e in s.entries)
        for e in old
            # A queued result from the abandoned edit must never overwrite undo.
            if haskey(revisions,e.id) && e.revision != revisions[e.id] || e.status in (:queued,:processing)
                e.revision=max(e.revision,get(revisions,e.id,0))+1
                review_queue!(s,e)
            end
        end
        s.entries=old; review_save!(s)
        return true
    end
end

function review_groups(s::ReviewSession)
    groups=Vector{ReviewEntry}[]
    for e in s.entries
        (isempty(groups) || e.starts) && push!(groups,ReviewEntry[])
        push!(groups[end],e)
    end
    return groups
end
function review_issues(s::ReviewSession)
    issues=String[]
    isempty(s.entries) && push!(issues,"Noch keine Aufnahme")
    for (n,group) in enumerate(review_groups(s))
        any(e->e.included,group) || push!(issues,"Dokument $n: alle Seiten ausgelassen")
        waiting=false
        for e in group
            e.status==:ready || push!(issues,"Aufnahme $(e.id): $(e.status==:error ? e.error : "Verarbeitung läuft")")
            if e.side==:front
                waiting && push!(issues,"Dokument $n: Rückseite fehlt")
                waiting=true
            elseif e.side==:back
                !waiting && push!(issues,"Dokument $n: Rückseite ohne Vorderseite")
                waiting=false
            else
                waiting && push!(issues,"Dokument $n: Rückseite fehlt")
                waiting=false
            end
        end
        waiting && push!(issues,"Dokument $n: Rückseite fehlt")
    end
    return unique(issues)
end
function review_wait(s::ReviewSession)
    barrier=Channel{Nothing}(1); put!(s.jobs,barrier); take!(barrier); s
end
function Base.close(s::ReviewSession)
    lock(s.lock) do
        close(s.jobs)
    end
    wait(s.worker)
    owned=lock(s.lock) do
        # A closed UI can still retain its draft through plot callbacks. It
        # must not retain four full-resolution capture buffers with it.
        close(s.capture_buffers)
        while isready(s.capture_buffers);take!(s.capture_buffers);end
        if s.processor isa ReviewProcessor
            close(s.processor.outputs)
            while isready(s.processor.outputs);take!(s.processor.outputs);end
        end
        owned=s.owns_ocr
        s.owns_ocr=false
        owned
    end
    owned && applicable(close,s.processor.ocr) && close(s.processor.ocr)
    nothing
end

"""Archive reviewed groups in order. A partial write is retryable without assigning duplicate IDs."""
function review_commit!(s::ReviewSession,a::DocumentArchive)
    lock(s.lock) do
        issues=review_issues(s)
        isempty(issues) || throw(ArgumentError(join(issues,"\n")))
        binding=joinpath(s.dir,"archive.json")
        if isfile(binding)
            destination=JSON3.read(read(binding,String),Dict{String,Any})["root"]
            realpath(a.root)==destination || throw(ArgumentError("Dieser Entwurf gehört bereits zum Archiv $destination"))
        else
            atomic_json(binding,Dict("root"=>realpath(a.root)))
        end
        s.commit_started=true; review_save!(s)
        paths=String[]
        for group in review_groups(s)
            key=first(group).id
            if haskey(s.committed,key)
                push!(paths,joinpath(a.root,document_record(a,s.committed[key])["pdf"])); continue
            end
            pages=PDFPage[]; textparts=String[]; sides=Dict{String,Any}[]; sheet=0
            for e in group
                e.side != :back && (sheet+=1)
                if e.included
                    img=permutedims(load(e.output))
                    push!(pages,PDFPage(img,e.words;dpi=s.dpi)); push!(textparts,text(e.words))
                end
                push!(sides,Dict("source"=>e.source,"sheet"=>sheet,"side"=>(e.side==:single ? "unknown" : String(e.side)),
                    "blank"=>e.blank,"pdf_page"=>(e.included ? length(pages) : nothing)))
            end
            # Omitting a nonblank page is an explicit review action; omit it from
            # the committed capture list, while retaining it in the draft.
            filter!(side->side["pdf_page"] !== nothing || side["blank"],sides)
            r=archive_document!(a,pages;text=join(textparts,"\n\f\n"),sources=[e.source for e in group],sides)
            s.committed[key]=r["number"]; review_save!(s)
            push!(paths,joinpath(a.root,r["pdf"]))
        end
        return paths
    end
end
