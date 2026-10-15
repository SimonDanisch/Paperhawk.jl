# Stable physical document numbers, independent of classification and filenames.
const MAX_DOCUMENT_NUMBER = 999_999_999_999
function document_number(n::Integer)
    1 <= n <= MAX_DOCUMENT_NUMBER || throw(ArgumentError("document number must be 1..$MAX_DOCUMENT_NUMBER"))
    return lpad(string(n),6,'0')
end

"""Write `content` to `path` through a temporary file beside it, renamed into place."""
function atomic_write(path, content)
    tmp, io = mktemp(dirname(path))
    try
        write(io, content)
        close(io)
        Base.Filesystem.rename(tmp, path)
    finally
        isopen(io) && close(io)
        isfile(tmp) && rm(tmp)
    end
    return path
end

atomic_json(path, data) = atomic_write(path, JSON3.write(data))
atomic_copy(source, path) = atomic_write(path, read(source))

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
    for dir in ("documents","records","text","numbers","sources","originals","images","markdown","reconstructed")
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

"""
    claim_number!(archive) -> n

The next free document number, taken for good: a directory under `numbers`.
One writer per archive (its pidfile) makes this race-free. Numbers are never
recycled.
"""
function claim_number!(a::DocumentArchive)
    existing = [parse(Int,n) for n in readdir(joinpath(a.root,"numbers")) if occursin(r"^\d+$",n)]
    n = isempty(existing) ? 1 : maximum(existing)+1
    while true
        dir = joinpath(a.root,"numbers",document_number(n))
        isdir(dir) || (mkdir(dir); return n)
        n += 1
    end
end

"""The first few words of a document's text, for its title."""
title(text::AbstractString; words::Int = 8) = join(first(split(text), words), ' ')

"""
    archive_document!(archive, pages; text, sources=[], sides=nothing, originals=[], images=[], scans=[]) -> record

Save a document under the next number. The source capture paths make a
repeated or interrupted commit idempotent: the same captures get the same
number, and an existing numbered document is never overwritten by a different
capture.

Beside the PDF and its text, each page's `originals` (the camera frame) and
`images` (the cleaned page) are kept as they are, and from the `scans`, the
pages as [`ScannedPage`](@ref)s, the document is written as Markdown and as a
vector reconstruction ([`markdown`](@ref), [`reconstruction`](@ref)).
"""
function archive_document!(a::DocumentArchive,pages::AbstractVector{PDFPage}; text::AbstractString,
        sources::AbstractVector{<:AbstractString}=String[], sides=nothing,
        originals::AbstractVector{<:AbstractString}=String[], images::AbstractVector{<:AbstractString}=String[],
        scans::AbstractVector{<:ScannedPage}=ScannedPage[])
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
        n = if !isempty(sourcekey) && isfile(sourcefile)
            old = JSON3.read(read(sourcefile,String),Dict{String,Any})["number"]
            isfile(recordpath(a,old)) && return document_record(a,old)
            old # recover a previously interrupted write with the same number
        else
            claim_number!(a)
        end
        label = document_number(n)
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
        heading = "$label — $(title(text))"
        kept(dir, files) = [begin
                                file = joinpath(dir, "$label-$k$(splitext(f)[2])")
                                atomic_copy(f, joinpath(a.root, file)); file
                            end for (k, f) in enumerate(files)]
        originalfiles, imagefiles = kept("originals", originals), kept("images", images)
        md = isempty(scans) ? nothing : joinpath("markdown", label*".md")
        html = isempty(scans) ? nothing : joinpath("reconstructed", label*".html")
        if !isempty(scans)
            atomic_write(joinpath(a.root,md), markdown(scans; title=heading))
            atomic_write(joinpath(a.root,html), reconstruction(scans; title=heading))
        end
        r = Dict{String,Any}("version"=>1,"number"=>n,"pdf"=>pdf,"text"=>txt,
            "originals"=>originalfiles,"images"=>imagefiles,"markdown"=>md,"reconstruction"=>html,
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
    pending_classifications(archive) -> count, or nothing while the archive is busy

How many documents still wait for their summary. Returns at once: `nothing`
when another task holds the archive.
"""
function pending_classifications(a::DocumentArchive)
    trylock(a.lock) || return nothing
    try
        rows = DBInterface.execute(a.db, "SELECT count(*) AS n FROM documents WHERE status='pending'")
        try
            return only(Int(r.n) for r in rows)
        finally
            DBInterface.close!(rows)
        end
    finally
        unlock(a.lock)
    end
end
