# From captured sides of sheets to documents.
#
# Every capture is cleaned, turned upright and read in a task of its own as
# soon as it is taken, so the PDFs are ready the moment scanning stops. The
# order of pages and where one document ends are only known then: in duplex
# mode the backs come after all the fronts, last sheet first, and separator
# sheets (a page with the separator's QR code) split the stack.

"""
    ProcessedPage

A capture cleaned and read: the page ready for the PDF, whether it is blank,
how far it was turned to stand upright, and its text.
"""
struct ProcessedPage
    page::PDFPage
    blank::Bool
    rotation::Int
    text::String
end

"""
    process_page(img; ocr, corners = nothing, dewarper = nothing, mode = :color, paper = :a4, dpi = 300, quality = 80) -> ProcessedPage

`img[x, y]` warped flat from the frame where the sheet has `corners` (or taken
as a flat page without them), cleaned, turned upright, checked for being blank
and read by `ocr` (an [`OCREngine`](@ref)), all on the GPU. `mode` is what goes
into the PDF: `:color`, `:gray` or `:bw`. Pass `dewarper = uvdoc(ocr)` to
straighten curved pages before cleaning and OCR. Construct once and reuse it
across pages.
"""
function prepare_page_image(img::AbstractMatrix; ocr::OCREngine, dewarper = nothing,
        mode::Symbol = :color, paper::Symbol = :a4, dpi = 300, rotation::Union{Nothing,Int}=nothing, image_ready=(_->nothing),corners=nothing,output_buffer=nothing)
    mode in (:color, :gray, :bw) || throw(ArgumentError("mode must be :color, :gray or :bw, not $(repr(mode))"))
    if ocr isa ProcessOCR
        result=process_prepare_page(ocr,img;dewarper,mode,dpi,rotation,corners)
        image_ready(result.image)
        return result
    end
    dewarper isa ProcessUVDoc && throw(ArgumentError("the dewarper must share the OCR's device: use uvdoc(ocr)"))
    return ongpu(ocr) do reader
        gpu_page(reader,img;corners,dpi,paper,mode,dewarper,rotation,image_ready,output_buffer)
    end
end

function process_page_image(img::AbstractMatrix; dpi=300, quality::Int=80, kw...)
    r=prepare_page_image(img;dpi,kw...)
    page=PDFPage(r.image,r.words;dpi,quality)
    return ProcessedPage(page,r.blank,r.rotation,text(r.words)),r.image
end

process_page(img::AbstractMatrix;kw...) = first(process_page_image(img;kw...))

"""
    Capture

One side of a sheet as it was captured: where the flat page was saved, whether
it is a separator sheet, and the task that cleans and reads it, giving a
[`ProcessedPage`](@ref) (`nothing` for separators).
"""
struct Capture
    raw::String
    separator::Bool
    processed::Union{Task, Nothing}
    number::Union{Int, Nothing}
end

Capture(raw::String,separator::Bool,processed::Union{Task,Nothing}) = Capture(raw,separator,processed,nothing)

"""
    capture(img, path; corners = nothing, kw...) -> Capture

Starts saving `img[x, y]` to `path`, with the sheet's `corners` next to it in
a `.json` file, and processing it, both in the background. Only the check for
the separator's QR code happens right away, so the beep can tell the two
apart. `kw` go to [`process_page`](@ref).
"""
function capture(img::AbstractMatrix, path::AbstractString; save_raw::Bool = true, corners = nothing, kw...)
    codes = qr_codes(img)
    number = numbered_separator(codes)
    separator = SEPARATOR_TEXT in codes || number !== nothing
    if save_raw
        mkpath(dirname(path))
        corners === nothing || atomic_json(corners_path(path), Dict("corners" => Tuple.(corners)))
        Threads.@spawn save(path, permutedims(img))
    end
    task = separator ? nothing : Threads.@spawn process_page(img; corners, kw...)
    return Capture(String(path), separator, task, number)
end

corners_path(raw::AbstractString) = splitext(raw)[1] * ".json"

# The sheet's corners saved with a capture, or `nothing` for a flat page.
function saved_corners(raw::AbstractString)
    file = corners_path(raw)
    isfile(file) || return nothing
    return Tuple(Vec2f.(JSON3.read(read(file, String))["corners"]))
end

"""
    documents(captures; duplex = false) -> Vector{Vector{Capture}}

The captures in reading order, split into documents at separator sheets, which
are left out. In duplex mode the captures are all fronts, then all backs
starting with the last sheet's, so side `i` and side `n + 1 - i` are the two
faces of one sheet; a sheet is a separator when either face is.
With `duplex_order=:interleaved`, consecutive captures are front/back pairs.
`grouping=:sheet` makes each physical sheet a separate document; `:batch`
keeps sheets together until a separator or the end of the scan.
"""
function document_groups(captures::AbstractVector{Capture}; duplex::Bool = false,
        duplex_order::Symbol=:stack, grouping::Symbol=:batch)
    duplex_order in (:stack,:interleaved) || throw(ArgumentError("duplex_order must be :stack or :interleaved"))
    grouping in (:batch,:sheet) || throw(ArgumentError("grouping must be :batch or :sheet"))
    n = length(captures)
    sheets = if duplex && iseven(n)
        duplex_order == :stack ? [[captures[i], captures[n + 1 - i]] for i in 1:(n ÷ 2)] :
            [[captures[i],captures[i+1]] for i in 1:2:n]
    else
        duplex && @warn "Duplex needs a back for every front, but there are $n sides; keeping them in the order they were scanned."
        [[c] for c in captures]
    end
    docs = NamedTuple{(:captures,:number),Tuple{Vector{Capture},Union{Int,Nothing}}}[]
    current = Capture[]
    number = nothing
    for sheet in sheets
        if any(c -> c.separator, sheet)
            isempty(current) || push!(docs, (captures=current,number=number))
            current = Capture[]
            numbers = unique([c.number for c in sheet if c.number !== nothing])
            length(numbers) <= 1 || throw(ArgumentError("different document numbers on the two sides of a separator"))
            number = isempty(numbers) ? nothing : only(numbers)
        else
            append!(current, sheet)
            if grouping == :sheet
                push!(docs,(captures=current,number=number))
                current = Capture[]
                number = nothing
            end
        end
    end
    isempty(current) || push!(docs, (captures=current,number=number))
    return docs
end

documents(captures::AbstractVector{Capture}; kw...) = [g.captures for g in document_groups(captures;kw...)]

"""
    title(text; words = 8) -> String

The first few words of a document's text, for the PDF's title.
"""
title(text::AbstractString; words::Int = 8) = join(first(split(text), words), ' ')

"""
    write_documents(dir, captures; duplex = false, keep_blank = false, name = basename(dir), archive = nothing) -> paths

One PDF per document in `dir`, named `name_01.pdf` and on. Blank pages are
left out unless `keep_blank`, which in duplex mode drops the empty backs.
With an archive, save under permanent document numbers and queue classification.
"""
function write_documents(dir::AbstractString, captures::AbstractVector{Capture}; duplex::Bool = false, keep_blank::Bool = false,
        name::AbstractString = basename(normpath(dir)), archive::Union{Nothing,DocumentArchive}=nothing,
        duplex_order::Symbol=:stack, grouping::Symbol=:batch)
    archive !== nothing && duplex && isodd(length(captures)) && throw(ArgumentError(
        "incomplete duplex scan: a front/back pair is missing; no document numbers have been assigned"))
    paths = String[]
    for group in document_groups(captures; duplex,duplex_order,grouping)
        doc = group.captures
        processed = ProcessedPage[fetch(c.processed) for c in doc]
        keep = [keep_blank || !p.blank for p in processed]
        pages = processed[keep]
        isempty(pages) && continue
        if archive !== nothing
            pdf_page = 0
            sides = [Dict{String,Any}("source"=>abspath(c.raw),
                "sheet"=>(duplex ? cld(i,2) : i),
                "side"=>(duplex ? (isodd(i) ? "front" : "back") : "unknown"),
                "blank"=>p.blank,"pdf_page"=>(keep[i] ? (pdf_page+=1) : nothing))
                for (i,(c,p)) in enumerate(zip(doc,processed))]
            record = archive_document!(archive,[p.page for p in pages];
                text=join((p.text for p in pages),"\n\f\n"),sources=[c.raw for c in doc],number=group.number,sides)
            path = joinpath(archive.root,record["pdf"])
            push!(paths,path)
            @info "archived document" number=record["number"] path
            continue
        end
        group.number === nothing || throw(ArgumentError("numbered cover sheets require archive=DocumentArchive(...)"))
        path = joinpath(dir, string(name, "_", lpad(length(paths) + 1, 2, '0'), ".pdf"))
        push!(paths, write_pdf(path, [p.page for p in pages]; title = title(join((p.text for p in pages), ' '))))
    end
    return paths
end

"""
    make_pdfs(dir; ocr, duplex = false, keep_blank = false, dewarper = nothing, archive = nothing, kw...) -> paths

The PDFs made again from the captures a scan saved in `dir/raw`, for instance
with another `mode`. `kw` go to [`process_page`](@ref).
When archiving, already imported capture groups reuse their number and PDF;
reprocessing never silently replaces an archived original.
"""
function make_pdfs(dir::AbstractString; ocr::OCREngine, duplex::Bool = false, keep_blank::Bool = false,
        archive::Union{Nothing,DocumentArchive}=nothing,duplex_order::Symbol=:stack,grouping::Symbol=:batch,kw...)
    raw = sort(filter(f -> startswith(f, "page_") && endswith(f, ".png"), readdir(joinpath(dir, "raw"))))
    captures = map(raw) do f
        path = joinpath(dir, "raw", f)
        capture(permutedims(load(path)), path; save_raw = false, corners = saved_corners(path), ocr, kw...)
    end
    return write_documents(dir, captures; duplex, keep_blank,archive,duplex_order,grouping)
end
