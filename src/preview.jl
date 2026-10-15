# Zoomed tiles of stored pages for the review UI, shrunk on the GPU by the same
# block mean as the live view.

"""
    PreviewRenderer(; select = anygpu)

A Mantle device of its own and the page last shown on it, uploaded once and
shrunk into tiles as the view pans and zooms. Use it on one thread.
"""
mutable struct PreviewRenderer{D}
    path::String
    dims::NTuple{2, Int}
    arrays::DeviceArrays{D}
end

PreviewRenderer(; select = anygpu) = PreviewRenderer("", (0, 0), DeviceArrays(Mantle.Device(select)))

function Base.close(r::PreviewRenderer)
    empty!(r.arrays)
    r.path, r.dims = "", (0, 0)
    return nothing
end

"""
    render(renderer, path, img, (x0, y0, x1, y1), scale) -> Matrix{RGB{N0f8}}

`img[x0+1:x1, y0+1:y1]`, the page stored at `path`, averaged over
`scale`×`scale` blocks.
"""
function render(r::PreviewRenderer, path::AbstractString, img::Matrix{RGB{N0f8}}, (x0, y0, x1, y1), scale::Int)
    a = r.arrays
    if r.path != path || r.dims != size(img)
        size(img) == r.dims || close(r)
        input = array!(a, :input, RGB{N0f8}, size(img)); source = array!(a, :source, RGB{Float32}, size(img))
        copyto!(input, img)
        # Scattered reads of packed three-byte RGB{N0f8} faulted on RADV.
        run!(g -> GF.convertpixels!(g, source, input), a, :source)
        r.path, r.dims = String(path), size(img)
    end
    w, h = max(1, (x1 - x0) ÷ scale), max(1, (y1 - y0) ÷ scale)
    blocks = array!(a, :blocks, GF.Blocks, (1,))
    copyto!(blocks, [GF.Blocks(scale, (x0, y0))])
    out = array!(a, (:tile, w, h), RGB{N0f8}, (w, h))
    run!(g -> GF.areadownscale!(g, out, a[:source], blocks), a, (:tile, w, h))
    pixels = Matrix{RGB{N0f8}}(undef, w, h)
    copyto!(pixels, out)
    return pixels
end

"""
    Previews(; select = anygpu, keep = 4)

Tiles of stored pages for the review UI: a [`PreviewRenderer`](@ref) on a
[`GPUWorker`](@ref) of its own, and the last `keep` pages decoded, so panning
and zooming one page decodes it once. `close` stops the worker and frees its
device memory.
"""
struct Previews
    worker::GPUWorker
    pages::Dict{String, Matrix{RGB{N0f8}}}
    order::Vector{String}
    keep::Int
    lock::ReentrantLock
end

Previews(; select = anygpu, keep::Int = 4) =
    Previews(GPUWorker(() -> PreviewRenderer(; select), "previews"), Dict{String, Matrix{RGB{N0f8}}}(), String[], keep, ReentrantLock())

Base.close(p::Previews) = close(p.worker)

"""
    pixels(f, previews, path)

`f(img)` with the page stored at `path`, decoded once and kept among the last
`keep`; the oldest one's buffer is reused for the next decode.
"""
function pixels(f, p::Previews, path::AbstractString)
    lock(p.lock) do
        img = get(p.pages, path, nothing)
        if img === nothing
            buffer = length(p.order) >= p.keep ? pop!(p.pages, popfirst!(p.order)) : nothing
            img = review_load_image(path; buffer)
            p.pages[path] = img
        end
        filter!(!=(path), p.order)
        push!(p.order, path)
        f(img)
    end
end

"""
    tile(previews, path, width, area = nothing) -> (; pixels, extent, fullsize)

The page at `path` inside `area = (x0, y0, x1, y1)` (all of it for `nothing`),
shrunk on the GPU to about `width` pixels across.
"""
function tile(p::Previews, path::AbstractString, width::Int, area = nothing)
    pixels(p, path) do img
        w, h = size(img)
        x0, y0, x1, y1 = area === nothing ? (0, 0, w, h) : area
        x0 = clamp(x0, 0, w - 1); y0 = clamp(y0, 0, h - 1)
        x1 = clamp(x1, x0 + 1, w); y1 = clamp(y1, y0 + 1, h)
        scale = max(1, cld(x1 - x0, width), cld(y1 - y0, 2width))
        tile = ongpu(r -> render(r, path, img, (x0, y0, x1, y1), scale), p.worker)
        (pixels = tile, extent = (x0, y0, x1, y1), fullsize = (w, h))
    end
end
