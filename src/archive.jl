# Stable physical document numbers, independent of classification and filenames.
const MAX_DOCUMENT_NUMBER = 999_999_999_999
function document_number(n::Integer)
    1 <= n <= MAX_DOCUMENT_NUMBER || throw(ArgumentError("document number must be 1..$MAX_DOCUMENT_NUMBER"))
    return lpad(string(n),6,'0')
end

function atomic_json(path, data)
    tmp, io = mktemp(dirname(path))
    try
        JSON3.write(io,data)
        close(io)
        Base.Filesystem.rename(tmp,path)
    finally
        isopen(io) && close(io)
        isfile(tmp) && rm(tmp)
    end
    return path
end

"""
    DocumentArchive(root; classifier=nothing, categories=DEFAULT_CATEGORIES)

An archive of numbered PDFs, OCR text, JSON records and a SQLite search index.
Numbers start at 1 and are assigned in import order. Numbers are permanent;
classification may change without moving the paper or renaming its PDF.
Classification runs in a queue after PDFs are saved. `wait_archive` waits for
that queue; `close` drains it. Pending jobs are resumed on reopening with a
classifier. A failed classification leaves the PDF intact and marks the record
for review. Use one open archive writer per directory.
"""
mutable struct DocumentArchive
    root::String
    categories::Vector{String}
    classifier::Any
    jobs::Channel{Any}
    worker::Task
    lock::ReentrantLock
    writer::Pidfile.LockMonitor
    db::SQLite.DB
end

function DocumentArchive(root::AbstractString; classifier=nothing, categories=DEFAULT_CATEGORIES)
    root = abspath(root)
    for dir in ("documents","records","text","numbers","sources")
        mkpath(joinpath(root,dir))
    end
    writer = Pidfile.mkpidlock(joinpath(root,".writer.pid");wait=false,stale_age=60)
    db = nothing
    try
        config = joinpath(root,"archive.toml")
        if isfile(config)
            settings = TOML.parsefile(config)
            get(settings,"version",0) == 1 || throw(ArgumentError("unsupported archive version"))
            categories = String.(settings["categories"])
        else
            categories = unique(String.(categories))
            isempty(categories) && throw(ArgumentError("categories must not be empty"))
            open(config,"w") do io
                TOML.print(io,Dict("version"=>1,"categories"=>categories))
            end
        end
        jobs = Channel{Any}(Inf)
        db = open_archive_database(root)
        archive = DocumentArchive(root,categories,classifier,jobs,Task(() -> nothing),ReentrantLock(),writer,db)
        records = archive_records(archive)
        sync_archive_database!(db,root,records)
        pending = classifier === nothing ? Int[] : [r["number"] for r in records if r["status"] == "pending"]
        archive.worker = @async for job in jobs
            if job isa Channel
                put!(job,nothing) # FIFO barrier for wait_archive
            else
                try
                    classify_record!(archive,job)
                catch err
                    @error "could not update archive record" number=job exception=(err,catch_backtrace())
                end
            end
        end
        errormonitor(archive.worker)
        for n in pending
            put!(jobs,n)
        end
        return archive
    catch
        db === nothing || close(db)
        close(writer)
        rethrow()
    end
end

recordpath(a::DocumentArchive,n) = joinpath(a.root,"records",document_number(n)*".json")
document_record(a::DocumentArchive,n::Integer) = JSON3.read(read(recordpath(a,n),String),Dict{String,Any})
archive_records(a::DocumentArchive) = sort!([JSON3.read(read(joinpath(a.root,"records",f),String),Dict{String,Any})
    for f in readdir(joinpath(a.root,"records")) if endswith(f,".json")];by=r->r["number"])

function save_record!(a::DocumentArchive,r)
    atomic_json(recordpath(a,r["number"]),r)
    index_record!(a.db,a.root,r)
    return r
end

"""Reserve permanent numbers for paper cover sheets. Unused numbers are never recycled."""
function reserve_numbers!(a::DocumentArchive,count::Integer=1)
    0 < count <= 10_000 || throw(ArgumentError("count must be 1..10000"))
    lock(a.lock) do
        isopen(a.jobs) || throw(ArgumentError("archive is closed"))
        existing = [parse(Int,n) for n in readdir(joinpath(a.root,"numbers")) if occursin(r"^\d+$",n)]
        n = isempty(existing) ? 1 : maximum(existing)+1
        numbers = Int[]
        while length(numbers) < count
            dir = joinpath(a.root,"numbers",document_number(n))
            try
                mkdir(dir) # atomic allocation, also against another process
                push!(numbers,n)
            catch
                isdir(dir) || rethrow()
            end
            n += 1
        end
        return numbers
    end
end

"""
    archive_document!(archive, pages; text, sources=[], number=nothing) -> record

Save a document under a new number or a pre-reserved cover-sheet number.
The source capture paths make repeated `stop!`/`make_pdfs` calls idempotent.
Existing numbered documents are never overwritten by a different capture.
"""
function archive_document!(a::DocumentArchive,pages::AbstractVector{PDFPage}; text::AbstractString,
        sources::AbstractVector{<:AbstractString}=String[], number::Union{Nothing,Integer}=nothing,sides=nothing)
    isempty(pages) && throw(ArgumentError("cannot archive an empty document"))
    if sides !== nothing
        numbered = [s["pdf_page"] for s in sides if s["pdf_page"] !== nothing]
        numbered == collect(eachindex(pages)) || throw(ArgumentError("sides must map every PDF page exactly once in reading order"))
        for s in sides
            s["side"] in ("front","back","unknown") || throw(ArgumentError("invalid side"))
            s["source"] isa AbstractString && s["blank"] isa Bool || throw(ArgumentError("invalid source or blank flag"))
            s["sheet"] === nothing || (s["sheet"] isa Integer && s["sheet"] > 0) || throw(ArgumentError("invalid sheet number"))
            s["pdf_page"] === nothing && !s["blank"] && throw(ArgumentError("only blank sides may be omitted"))
        end
    end
    lock(a.lock) do
        isopen(a.jobs) || throw(ArgumentError("archive is closed"))
        src = abspath.(sources)
        sourcekey = isempty(src) ? "" : bytes2hex(SHA.sha256(JSON3.write(src)))
        sourcefile = joinpath(a.root,"sources",sourcekey*".json")
        if !isempty(sourcekey) && isfile(sourcefile)
            old = JSON3.read(read(sourcefile,String),Dict{String,Any})["number"]
            number === nothing || number == old || throw(ArgumentError("capture already belongs to document $old"))
            isfile(recordpath(a,old)) && return document_record(a,old)
            number = old # recover a previously interrupted write with the same number
        end
        n = number === nothing ? only(reserve_numbers!(a)) : Int(number)
        label = document_number(n)
        isdir(joinpath(a.root,"numbers",label)) || throw(ArgumentError("number $label has not been reserved in this archive"))
        if isfile(recordpath(a,n))
            old = document_record(a,n)
            !isempty(sourcekey) && old["source_key"] == sourcekey && return old
            throw(ArgumentError("document $label already exists; refusing to overwrite it"))
        end
        # Claim a number before any PDF write. A crash leaves a recoverable
        # association; another scan may not take over that number.
        claim = joinpath(a.root,"numbers",label,"claim.json")
        if isfile(claim)
            old = JSON3.read(read(claim,String),Dict{String,Any})
            !isempty(sourcekey) && old["source_key"] == sourcekey ||
                throw(ArgumentError("number $label is already claimed by another capture"))
        else
            atomic_json(claim,Dict("source_key"=>sourcekey,"sources"=>src))
        end
        isempty(sourcekey) || atomic_json(sourcefile,Dict("number"=>n))
        pdf = joinpath("documents",label*".pdf")
        txt = joinpath("text",label*".txt")
        dest = joinpath(a.root,pdf)
        tmp = tempname(dirname(dest))
        try
            write_pdf(tmp,pages;title="$label — $(title(text))")
            mv(tmp,dest;force=true) # only this reserved, uncommitted number
        finally
            isfile(tmp) && rm(tmp)
        end
        write(joinpath(a.root,txt),text)
        r = Dict{String,Any}("version"=>1,"number"=>n,"pdf"=>pdf,"text"=>txt,
            "pages"=>length(pages),"sources"=>src,"source_key"=>sourcekey,
            "sides"=>(sides === nothing ? [Dict("pdf_page"=>i,"sheet"=>nothing,"side"=>"unknown","source"=>"","blank"=>false) for i in eachindex(pages)] : sides),
            "created"=>string(Dates.now()),"status"=>"pending","category"=>"Unsortiert",
            "sender"=>"","date"=>"","title"=>title(text),"summary"=>"",
            "needs_review"=>true,"model"=>"","error"=>"")
        save_record!(a,r) # commit after PDF and text exist, then update search index
        a.classifier === nothing || put!(a.jobs,n)
        return r
    end
end

function classify_record!(a::DocumentArchive,n)
    try
        r = document_record(a,n)
        r["status"] == "pending" || return
        content = read(joinpath(a.root,r["text"]),String)
        isempty(strip(content)) && throw(ArgumentError("no OCR text; document needs review"))
        result = a.classifier(content,a.categories)
        metadata = parse_classification(JSON3.write(result.metadata),a.categories)
        lock(a.lock) do
            current = document_record(a,n)
            current["status"] == "pending" || return # preserve a user's correction
            merge!(current,metadata)
            current["status"] = metadata["needs_review"] ? "needs_review" : "classified"
            current["model"] = String(result.model)
            current["model_response"] = String(result.raw)
            current["error"] = ""
            save_record!(a,current)
        end
    catch err
        lock(a.lock) do
            current = document_record(a,n)
            current["status"] == "pending" || return
            current["status"],current["needs_review"] = "needs_review",true
            current["error"] = sprint(showerror,err)
            save_record!(a,current)
        end
    end
    return nothing
end

"""Wait for all currently queued classifications, without closing the archive."""
function wait_archive(a::DocumentArchive)
    barrier = Channel{Nothing}(1)
    put!(a.jobs,barrier)
    take!(barrier)
    return archive_records(a)
end

function Base.close(a::DocumentArchive)
    close(a.jobs)
    try
        wait(a.worker)
    finally
        try
            close(a.db)
        finally
            close(a.writer)
        end
    end
    return nothing
end

"""
Search indexed OCR and metadata using word prefixes, ignoring case and accents.
Returns records including document number and PDF path, ranked by relevance.
Filters: category, sender (exact), number, date_from, date_to. Paginate with
limit=100 and offset=0. Empty query lists documents in number order.
"""
function search_documents(a::DocumentArchive,query::AbstractString=""; kw...)
    lock(a.lock) do
        isopen(a.jobs) || throw(ArgumentError("archive is closed"))
        search_database(a.db,query;kw...)
    end
end

"""Correct model metadata while preserving the document number and PDF."""
function update_document!(a::DocumentArchive,n::Integer; kw...)
    allowed = Set([:category,:sender,:date,:title,:summary,:needs_review])
    all(k -> k in allowed,keys(kw)) || throw(ArgumentError("only metadata may be edited"))
    lock(a.lock) do
        isopen(a.jobs) || throw(ArgumentError("archive is closed"))
        r = document_record(a,n)
        metadata = Dict{String,Any}(String(k)=>get(r,String(k),"") for k in allowed)
        merge!(metadata,Dict(String(k)=>v for (k,v) in kw))
        # An explicit correction resolves review unless the caller says otherwise.
        haskey(kw,:needs_review) || (metadata["needs_review"]=false)
        parsed = parse_classification(JSON3.write(metadata),[a.categories;"Unsortiert"])
        merge!(r,parsed)
        r["status"] = parsed["needs_review"] ? "needs_review" : "reviewed"
        save_record!(a,r)
        return r
    end
end

"""Queue a saved document again, e.g. after choosing a better model."""
function retry_classification!(a::DocumentArchive,n::Integer)
    a.classifier === nothing && throw(ArgumentError("archive has no classifier"))
    lock(a.lock) do
        isopen(a.jobs) || throw(ArgumentError("archive is closed"))
        r = document_record(a,n)
        r["status"],r["error"] = "pending",""
        save_record!(a,r)
        put!(a.jobs,n)
    end
    return nothing
end

"""
    number_sheets(archive, path; count=10, dpi=150) -> numbers

Reserve numbers and print one QR cover sheet per document. Place each cover
BEFORE its document; the scanner uses its number and omits the cover from the
PDF. Keep the cover with the paper original in the physical folder.
"""
function number_sheets(a::DocumentArchive,path::AbstractString; count::Int=10,dpi=150)
    numbers = reserve_numbers!(a,count)
    pages = PDFPage[]
    for n in numbers
        w,h = paper_size(:a4;dpi)
        img = fill(Gray(true),w,h)
        code = qr_image("ASCANNER:DOC:"*document_number(n);module_size=max(1,round(Int,2.5dpi/25.4)))
        cw,ch = size(code)
        x0,y0 = (w-cw)÷2,(h-ch)÷2
        img[x0+1:x0+cw,y0+1:y0+ch] .= code
        label = Word("Dokument "*document_number(n),round(Int,.2w),round(Int,.2h),0,0,
            round(Int,.2h),round(Int,.05h),100)
        push!(pages,PDFPage(img,[label];dpi,visible=true))
    end
    write_pdf(path,pages;title="Paperhawk Dokumentnummern")
    return numbers
end
