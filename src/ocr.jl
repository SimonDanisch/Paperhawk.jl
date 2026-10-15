# Reading a page: PP-OCRv6 on the GPU, which way up it is and the words on it
# with their boxes.

"""
    Word

A word read off a page: its text, its box in pixels of the page (`x`, `y` of
the top-left corner, `width`, `height`), the box of its line, and the engine's
confidence from 0 to 100.
"""
struct Word
    text::String
    x::Int
    y::Int
    width::Int
    height::Int
    line_y::Int
    line_height::Int
    confidence::Float32
end

# Persist existing word records directly; rebuilding dictionaries for every
# word on every draft update creates garbage proportional to the whole stack.
JSON3.StructTypes.StructType(::Type{Word})=JSON3.StructTypes.Struct()

"""The words of PP-OCR's lines, each with its line's box and confidence."""
function words(lines::AbstractVector{PPOCRRunner.TextLine})
    out = Word[]
    for line in lines
        x0, y0, x1, y1 = line.box
        top, h = round(Int, y0), max(1, round(Int, y1 - y0))
        for (t, a, b) in line.words
            push!(out, Word(t, round(Int, a), top, max(1, round(Int, b - a)), h, top, h, 100 * line.score))
        end
    end
    return out
end

text(words::AbstractVector{Word}) = join((w.text for w in words), ' ')

"""
    PageReader(device)

What the OCR thread owns: PP-OCRv6 on `device`, the page buffers sized for the
last page, and UVDoc once a page asks for it. `close` frees all of it there.
"""
mutable struct PageReader{D, M}
    device::D
    model::M
    workspace::Union{Nothing, PageWorkspace}
    dewarper::Union{Nothing, UVDocRunner.UVDoc}
end

PageReader(device) = PageReader(device, PPOCRRunner.ppocr(; backend = Mantle.backend(device)), nothing, nothing)

function Base.close(r::PageReader)
    r.workspace === nothing || close(r.workspace)
    r.dewarper === nothing || close(r.dewarper)
    r.workspace, r.dewarper = nothing, nothing
    close(r.model)
    return nothing
end

"""UVDoc on the reader's device, loaded on first use."""
function dewarper!(r::PageReader)
    r.dewarper === nothing && (r.dewarper = UVDocRunner.uvdoc(; backend = r.model.backend))
    return r.dewarper
end

"""
    PaddleOCR(; select = anygpu)

PP-OCRv6 medium on the GPU, through JuliaVision's `PPOCRRunner`: a detector
for the lines and a recogniser for each, 18710 characters including German's,
and PP-LCNet for which way up a page is. A [`GPUWorker`](@ref) of its own owns
the device `select` names, the models and the page buffers, and runs the
requests one at a time.

`demand` counts the foreground work waiting for this engine: queued pages and
an active camera. Background work on the same device, the classifier, waits
while it is above zero.
"""
struct PaddleOCR
    worker::GPUWorker
    demand::Threads.Atomic{Int}
end

PaddleOCR(; select = anygpu) =
    PaddleOCR(GPUWorker(() -> PageReader(Mantle.Device(select)), "OCR"), Threads.Atomic{Int}(0))

Base.close(e::PaddleOCR) = close(e.worker)
Base.show(io::IO, e::PaddleOCR) = print(io, "PaddleOCR(", e.worker, ")")

"""
    ongpu(f, engine::PaddleOCR)

`f(reader)` on the engine's thread with its [`PageReader`](@ref), counted as
foreground demand while it waits and runs.
"""
function ongpu(f, e::PaddleOCR)
    hold!(e, 1)
    try
        return ongpu(f, e.worker)
    finally
        hold!(e, -1)
    end
end

"""
    hold!(engine, delta)

Raise or lower the engine's foreground demand. Nothing for no engine.
"""
hold!(e::PaddleOCR, delta::Int) = (Threads.atomic_add!(e.demand, delta); nothing)
hold!(::Nothing, ::Int) = nothing

"""
    yield_to(demand)

Wait while foreground work is queued: background work calls this between
steps, so a page in the queue is read before the next prompt chunk. Work
already submitted to the GPU finishes first.
"""
function yield_to(demand::Threads.Atomic{Int})
    yield()
    while demand[] > 0
        sleep(0.001)
    end
    return nothing
end
yield_to(::Nothing) = nothing

"""
    orientation(engine, img) -> degrees

How far, clockwise, `img[x, y]` must be turned for its text to stand upright:
0, 90, 180 or 270. PP-LCNet's page classifier needs no readable text.
"""
orientation(e::PaddleOCR, img::AbstractMatrix) = ongpu(r -> PPOCRRunner.orientation(r.model, img), e)

"""
    read_words(engine, img) -> Vector{Word}

The words on `img[x, y]`, an upright page.
"""
read_words(e::PaddleOCR, img::AbstractMatrix) = ongpu(r -> words(PPOCRRunner.read_lines(r.model, img)), e)

"""
    process_page(ocr, img; corners = nothing, dewarp = false, mode = :color, paper = :a4, dpi = 300,
                 rotation = nothing, image_ready = image -> nothing, output = nothing)
        -> (; image, words, blank, rotation, layout)

`img[x, y]` warped flat from the frame where the sheet has `corners` (or taken
as a flat page without them), straightened by UVDoc with `dewarp`, cleaned,
turned upright, checked for being blank and read, all on `ocr`'s GPU, and its
[`PageLayout`](@ref) measured. `mode` is the image's format, see
[`packed`](@ref). `rotation` overrides the detected one. `image_ready(image)`
runs with the finished image before the words are read, so it can be shown and
saved meanwhile.
"""
function process_page(ocr::PaddleOCR, img::AbstractMatrix; mode::Symbol = :color, kw...)
    mode in (:color, :gray, :bw) || throw(ArgumentError("mode must be :color, :gray or :bw, not $(repr(mode))"))
    return ongpu(r -> process_page(r, img; mode, kw...), ocr)
end

function process_page(r::PageReader, img::AbstractMatrix; corners = nothing, dewarp::Bool = false, mode::Symbol = :color,
        paper::Symbol = :a4, dpi = 300, rotation::Union{Nothing, Int} = nothing, image_ready = (_ -> nothing), output = nothing)
    dims = corners === nothing ? size(img) : page_size(corners, paper; dpi)
    min(dims...) >= 120 || throw(ArgumentError("a page needs both sides of at least 120 pixels, not $dims"))
    s = workspace!(r, img, dims)
    upload!(s, img; corners)
    dewarp && unwarp!(r, s)
    blank = cleanup!(s)
    degrees = rotation === nothing ? (blank ? 0 : orientation(r, s)) : mod(rotation, 360)
    degrees in (0, 90, 180, 270) || throw(ArgumentError("can only rotate by multiples of 90 degrees"))
    page = rotated!(r, s, degrees)
    image = packed(s, page, mode, output)
    image_ready(image)
    lines = blank ? PPOCRRunner.TextLine[] : PPOCRRunner.read_lines(r.model, page)
    layout = blank ? PageLayout(size(page)) : layout!(s, page, lines)
    return (; image, words = words(lines), blank, rotation = degrees, layout)
end
