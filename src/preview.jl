# Zoomed tiles of stored pages for the review UI, shrunk on the GPU with the
# same kernel as the live view.

"""
    PreviewRenderer(; select = info -> true)

A Mantle device of its own and the page last shown on it, uploaded once and
shrunk into tiles as the view pans and zooms. Use it on one thread.
"""
mutable struct PreviewRenderer{D}
    device::D
    path::String
    dims::NTuple{2, Int}
    buffers::Dict{Symbol, Any}
    plans::Dict{Any, Any}
end

PreviewRenderer(; select = info -> true) =
    PreviewRenderer(Mantle.Device(select), "", (0, 0), Dict{Symbol, Any}(), Dict{Any, Any}())

function release!(r::PreviewRenderer)
    Mantle.waitidle(r.device)
    foreach(Mantle.free!, values(r.plans)); empty!(r.plans)
    foreach(Mantle.free!, values(r.buffers)); empty!(r.buffers)
    r.path, r.dims = "", (0, 0)
    nothing
end
Base.close(r::PreviewRenderer) = release!(r)

"""
    render(renderer, path, img, (x0, y0, x1, y1), scale) -> Matrix{RGB{N0f8}}

`img[x0+1:x1, y0+1:y1]`, the page stored at `path`, averaged over
`scale`×`scale` blocks.
"""
function render(r::PreviewRenderer, path::AbstractString, img::Matrix{RGB{N0f8}}, (x0, y0, x1, y1), scale::Int)
    if r.path != path || r.dims != size(img)
        size(img) == r.dims || release!(r)
        buffer(name, T) = get!(() -> Mantle.Buffer(r.device, T, size(img)), r.buffers, name)
        input = buffer(:input, RGB{N0f8}); source = buffer(:source, RGB{Float32})
        copyto!(input, img)
        plan = get!(r.plans, :source) do
            g = Mantle.Graph(r.device)
            Mantle.dispatch!(g, page_copy!, (source, input), length(img); name = "page to float")
            Mantle.record!(Mantle.Plan(g))
        end
        Mantle.run!(plan)
        r.path, r.dims = String(path), size(img)
    end
    w, h = max(1, (x1 - x0) ÷ scale), max(1, (y1 - y0) ÷ scale)
    params = get!(() -> Mantle.Buffer(r.device, Int32, (3,)), r.buffers, :params)
    copyto!(params, Int32[scale, x0, y0])
    out = get!(() -> Mantle.Buffer(r.device, RGB{N0f8}, (w * h,)), r.buffers, Symbol(:tile_, w, :x, h))
    plan = get!(r.plans, (:tile, w, h)) do
        g = Mantle.Graph(r.device)
        Mantle.dispatch!(g, shrink!, (out, r.buffers[:source], params, w), w * h; name = "preview tile")
        Mantle.record!(Mantle.Plan(g))
    end
    Mantle.run!(plan)
    pixels = Matrix{RGB{N0f8}}(undef, w, h)
    copyto!(vec(pixels), out)
    return pixels
end

const PREVIEW_REQUESTS = Ref{Union{Nothing, Channel{Any}}}(nothing)
const PREVIEW_SERVICE_LOCK = ReentrantLock()

# One renderer per process, on a GPU thread of its own, started on first use.
function preview_requests()
    lock(PREVIEW_SERVICE_LOCK) do
        queue = PREVIEW_REQUESTS[]
        queue === nothing || return queue
        queue = Channel{Any}(Inf)
        errormonitor(spawn_gpu_owner("previews") do
            renderer = PreviewRenderer()
            try
                for (args, reply) in queue
                    put!(reply, try
                        (Base.invokelatest(render, renderer, args...), nothing)
                    catch err
                        (nothing, CapturedException(err, catch_backtrace()))
                    end)
                end
            finally
                close(renderer)
            end
        end)
        PREVIEW_REQUESTS[] = queue
    end
end

"""
    render_preview(path, img, area, scale) -> Matrix{RGB{N0f8}}

[`render`](@ref) on this process's preview GPU thread.
"""
function render_preview(path, img, area, scale)
    reply = Channel{Any}(1)
    put!(preview_requests(), ((path, img, area, scale), reply))
    pixels, err = take!(reply)
    err === nothing || throw(err)
    return pixels
end

"""Stop this process's preview renderer and free its GPU memory."""
function close_previews!()
    lock(PREVIEW_SERVICE_LOCK) do
        queue = PREVIEW_REQUESTS[]
        queue === nothing || close(queue)
        PREVIEW_REQUESTS[] = nothing
    end
    nothing
end
