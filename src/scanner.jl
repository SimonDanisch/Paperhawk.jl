# Scanning hands-free from start to PDF.

"""
    Scanner

A running hands-free scan: the task that reads frames, the folder everything
goes to, the sides captured so far and, once stopped, the PDFs. Stop it with
[`stop!`](@ref).
"""
mutable struct Scanner
    dir::String
    duplex::Bool
    keep_blank::Bool
    captures::Vector{Capture}
    documents::Vector{String}
    running::Threads.Atomic{Bool}
    task::Task
    archive::Union{Nothing,DocumentArchive}
    duplex_order::Symbol
    grouping::Symbol
end

function Base.show(io::IO, s::Scanner)
    separators = count(c -> c.separator, s.captures)
    print(io, "Scanner(", repr(s.dir), ", ", length(s.captures) - separators, " pages, ", separators, " separators, ",
        s.duplex ? "duplex, " : "", s.running[] ? "running" : "stopped", ")")
end

"""
    start(cam; ocr, dir = joinpath("scans", <date and time>), duplex = false, mode = :color,
          paper = :a4, dpi = 300, dewarper = nothing, quality = 80,
          keep_blank = false, trigger = Trigger(), archive = nothing, verbose = true, kw...) -> Scanner

Scans hands-free from `cam` until [`stop!`](@ref). Every sheet put down and
left still is saved to `dir/raw` with its corners, then warped flat, cleaned
and read on the GPU in the background. One beep means a page, two beeps a
separator sheet (see [`separator_sheet`](@ref)), which ends a document.

With `duplex`, scan the fronts of the whole stack, turn the stack over, and
scan the backs: the pages are put back in order, and empty backs dropped.
`mode` is what goes into the PDF: `:color`, `:gray` or `:bw`. `ocr` reads the
pages, see [`PaddleOCR`](@ref). `dewarper = uvdoc(ocr)` additionally
straightens curved pages before OCR. `kw` go to [`PageDetector`](@ref).

With `archive = DocumentArchive(...)`, `stop!` numbers documents from 1 onward
in scan order and queues classification. File the paper in that same order.
Use `grouping=:sheet` for one document per physical sheet (front and back share
a number), or the default `:batch` to keep all captured sheets in one document.
`duplex_order=:interleaved` captures front/back/front/back; the default `:stack`
captures all fronts, then backs in reverse sheet order. Blank backs must also
be captured to preserve pairing; they can be omitted from the final PDF.
"""
function start(cam::Camera; ocr::OCREngine, dir::AbstractString = joinpath("scans", Dates.format(Dates.now(), "yyyy-mm-dd_HHMMSS")),
        duplex::Bool = false, mode::Symbol = :color, paper::Symbol = :a4, dpi = 300,
        dewarper = nothing,
        archive::Union{Nothing,DocumentArchive}=nothing,
        duplex_order::Symbol=:stack,grouping::Symbol=:batch,
        quality::Int = 80, keep_blank::Bool = false, trigger::Trigger = Trigger(), verbose::Bool = true, kw...)
    document_groups(Capture[];duplex,duplex_order,grouping) # validate before opening the camera loop
    rawdir = joinpath(dir,"raw")
    isdir(rawdir) && !isempty(readdir(rawdir)) && throw(ArgumentError(
        "scan directory already contains captures; choose a new dir or use make_pdfs to reprocess it"))
    running = Threads.Atomic{Bool}(true)
    captures = Capture[]
    task = spawn_gpu_owner("scanner") do
        detector = PageDetector(; kw...)
        img = Matrix{RGB{N0f8}}(undef, cam.width, cam.height)
        try
            while running[]
                frame!(img, cam)
                detection = detect!(detector, img)
                update!(trigger, detection, time()) || continue
                path = joinpath(dir, "raw", string("page_", lpad(length(captures) + 1, 3, '0'), ".png"))
                # The next frame reuses `img`; the capture keeps its own pixels.
                c = capture(copy(img), path; corners = detection.page.corners, paper, mode, ocr, dewarper, dpi, quality)
                push!(captures, c)
                beep(c.separator ? 2 : 1)
                verbose && @info c.separator ? "separator" : "side $(length(captures))"
            end
        catch err
            @error "scanner stopped" exception = (err, catch_backtrace())
        finally
            running[] = false
            close(detector)
        end
    end
    return Scanner(String(dir), duplex, keep_blank, captures, String[], running, task, archive,duplex_order,grouping)
end

"""
    stop!(scanner) -> paths

Stops scanning, waits for the last pages to be read, and writes one PDF per
document into the scanner's folder or configured archive. Does not wait for
the archive's LLM; use `wait_archive(archive)` when its metadata is needed.
"""
function stop!(s::Scanner)
    s.running[] = false
    wait(s.task)
    s.documents = write_documents(s.dir, s.captures; s.duplex, s.keep_blank, archive=s.archive,s.duplex_order,s.grouping)
    return s.documents
end

"""
    separator_sheet(path = "separator.pdf"; dpi = 300) -> path

An A4 page to print and put between documents: the separator's QR code, large,
and a line saying what it is.
"""
function separator_sheet(path::AbstractString = "separator.pdf"; dpi = 300)
    w, h = paper_size(:a4; dpi)
    page = fill(Gray(true), w, h)
    code = qr_image(SEPARATOR_TEXT; module_size = round(Int, 3.2 * dpi / 25.4))
    cw, ch = size(code)
    x0, y0 = (w - cw) ÷ 2, (h - ch) ÷ 2
    page[(x0 + 1):(x0 + cw), (y0 + 1):(y0 + ch)] .= code
    label = Word("Paperhawk - Trennblatt / separator", round(Int, 0.18w), round(Int, 0.2h), round(Int, 0.64w), 0, round(Int, 0.2h), round(Int, 0.03h), 100)
    return write_pdf(path, [PDFPage(page, [label]; dpi, visible = true)]; title = "Paperhawk separator")
end

