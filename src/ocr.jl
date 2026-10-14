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

"""
    OCREngine

What reads the words off a page: [`PaddleOCR`](@ref) on a thread of its own,
or in the separate processing process. Each implements `read_words(engine, img; dpi)`.
"""
abstract type OCREngine end

"""
    PaddleOCR(; execution=:thread, backend=nothing)

PP-OCRv6 medium on the GPU, through JuliaVision's `PPOCRRunner`: a detector
for the lines and a recogniser for each, 18710 characters including German's,
and PP-LCNet for which way up a page is.

By default a dedicated Julia thread owns the models and reusable GPU buffers.
Requests are serialized on that thread. Use `execution=:process` to explicitly
request the separate-process implementation. An explicitly supplied `backend`
uses `execution=:local`; construct it on that backend's owning thread.
"""
struct PaddleOCR{M} <: OCREngine
    model::M
    requests::Channel{Any}
end

struct ProcessOCR <: OCREngine
    pid::Int
    id::Int
end

function PaddleOCR(; backend=nothing,execution=backend===nothing ? :thread : :local,kw...)
    execution in (:process,:thread,:local) || throw(ArgumentError("execution must be :process, :thread or :local"))
    backend!==nothing && execution!=:local && throw(ArgumentError("an existing backend requires execution=:local on its owning thread"))
    execution==:thread && return threaded_paddle(;kw...)
    execution==:process && return process_model(:ocr,(;kw...))
    model = PPOCRRunner.ppocr(; backend=backend===nothing ? Mantle.defaultbackend() : backend,kw...)
    return PaddleOCR(model,paddle_requests(model))
end

const PADDLE_WORKERS=IdDict{Any,Task}()
const PADDLE_THREAD_LOCK=ReentrantLock()
const PADDLE_THREAD_REQUESTS=Ref{Union{Nothing,Channel{Any}}}(nothing)

function threaded_paddle(;kw...)
    # GLFW initialization belongs to thread 1. A persistent executor then owns
    # the default device: closing/reopening a model must not move that device
    # to whichever thread the scheduler happens to choose next.
    requests=lock(PADDLE_THREAD_LOCK) do
        queue=PADDLE_THREAD_REQUESTS[]
        if queue===nothing
            queue=Channel{Any}(Inf)
            task=spawn_gpu_owner("OCR") do
                for (f,reply) in queue
                    put!(reply,try
                        (Base.invokelatest(f),nothing)
                    catch err
                        (nothing,err isa OutOfMemoryError ? err : CapturedException(err,catch_backtrace()))
                    end)
                end
            end
            errormonitor(task)
            PADDLE_THREAD_REQUESTS[]=queue
        end
        queue
    end
    reply=Channel{Any}(1)
    construct=()->begin
        model=PPOCRRunner.ppocr(;kw...)
        PaddleOCR(model,paddle_requests(model))
    end
    put!(requests,(construct,reply))
    result,err=take!(reply)
    err===nothing || throw(err)
    result
end

function Base.close(e::PaddleOCR)
    close(e.requests)
    task=pop!(PADDLE_WORKERS,e.requests,nothing)
    task===nothing || wait(task)
    nothing
end

Base.show(io::IO,::ProcessOCR)=print(io,"PaddleOCR(background process)")

# The model and its page buffers belong to this worker, on the thread that
# loaded the model; closing the request channel closes them there.
function paddle_requests(model)
    requests = Channel{Any}(Inf)
    reader = PageReader(model)
    worker = @async try
      for (f, reply) in requests
        put!(reply, try
            # Requests may come from code loaded after this long-lived worker
            # started (GUI callbacks and Revise in particular).
            (Base.invokelatest(f,reader), nothing)
        catch err
            (nothing, err isa OutOfMemoryError ? err : CapturedException(err, catch_backtrace()))
        end)
      end
    finally
        close(reader)
    end
    errormonitor(worker)
    PADDLE_WORKERS[requests]=worker
    return requests
end

"""
    ongpu(f, engine::PaddleOCR)

`f(reader)`, run by the engine's worker on the thread that owns the GPU, with
the engine's [`PageReader`](@ref).
"""
const OCR_PENDING=Threads.Atomic{Int}(0)
const SCAN_ACTIVE=Threads.Atomic{Int}(0)

# LLM prompt chunks and generated tokens yield to pending OCR submissions.
# This is cooperative priority: an already submitted GPU chunk finishes first.
function wait_for_ocr()
    yield()
    while OCR_PENDING[]>0 || SCAN_ACTIVE[]>0
        sleep(0.001)
    end
    nothing
end

function ongpu(f, e::PaddleOCR)
    reply = Channel{Any}(1)
    Threads.atomic_add!(OCR_PENDING,1)
    processing_pid=PROCESS_PID[]
    process_ocr_activity(processing_pid,1)
    try
        put!(e.requests, (f, reply))
        result, err = take!(reply)
        err === nothing || throw(err)
        return result
    finally
        Threads.atomic_sub!(OCR_PENDING,1)
        process_ocr_activity(processing_pid,-1)
    end
end

Base.show(io::IO, e::PaddleOCR) = print(io, "PaddleOCR(", e.model, ")")

"""
    default_ocr() -> PaddleOCR

PP-OCRv6 on the GPU, on a thread of its own.
"""
default_ocr() = PaddleOCR()

"""
    orientation(engine, img; dpi = 300) -> degrees

How far, clockwise, `img[x, y]` must be turned for its text to stand upright:
0, 90, 180 or 270. PP-LCNet's page classifier needs no readable text.
"""
function orientation(e::PaddleOCR, img::AbstractMatrix; dpi = 300)
    rgb = eltype(img) <: AbstractRGB ? img : map(c -> (v = luminance(c); RGB{Float32}(v, v, v)), img)
    return ongpu(m -> gpu_page_orientation(m, rgb), e)
end

"""
    read_words(engine, img; dpi = 300) -> Vector{Word}

The words on `img[x, y]`, an upright page.
"""
function read_words(e::PaddleOCR, img::AbstractMatrix; dpi = 300)
    rgb = eltype(img) <: AbstractRGB ? img : map(c -> (v = luminance(c); RGB{Float32}(v, v, v)), img)
    lines = ongpu(m -> gpu_read_lines(m, rgb), e)
    words = Word[]
    for line in lines
        x0, y0, x1, y1 = line.box
        top, h = round(Int, y0), max(1, round(Int, y1 - y0))
        for (t, a, b) in line.words
            push!(words, Word(t, round(Int, a), top, max(1, round(Int, b - a)), h, top, h, 100 * line.score))
        end
    end
    return words
end

text(words::AbstractVector{Word}) = join((w.text for w in words), ' ')

"""Create UVDoc on the same device-owning worker as a thread/local OCR engine."""
function uvdoc(e::PaddleOCR;kw...)
    ongpu(r->UVDocRunner.uvdoc(;backend=r.model.backend,kw...),e)
end
