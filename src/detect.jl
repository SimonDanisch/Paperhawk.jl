# Finding the sheet in a camera frame, on the GPU.
#
# Images are `img[x, y]`, x first, the way frames come out of the decoder.
#
# One feature decides what is paper: whiteness, bright and colourless. Neutral
# paper has it, a wooden or dark desk does not, and a shadow on the paper keeps
# most of it. On the frame shrunk to about `detect_size` pixels across, Otsu's
# threshold on whiteness gives the bright regions; an opening cuts thin bridges
# and connected components separate them. Each of the largest regions is
# reduced to its extreme pixels in 16 directions. The largest quadrilateral
# through those is the rough sheet, accepted when it fills the region and keeps
# clear of the frame's border.
#
# The edges are then measured along short profiles across them: the outermost
# steep fall of whiteness, since a fold or a shadow on the sheet can fall as
# steeply but lies inside. First in the shrunk frame with a wide search, since
# a shadow can bite into the region, then twice in the full frame, to a fraction
# of a pixel. The last pass samples along the edges the one before found, so
# where it samples no longer depends on the rough outline. Paper edges
# are wavy by about a millimetre. A line fit with smooth (Huber) weights keeps
# the corners from jumping when single points change between frames, and
# corners from lines rather than pixels keep the skew well under a degree.

"""
    Page

A sheet found in a frame. `corners` are in pixel coordinates of the frame
(x is the first index, y the second, pixel centres at whole numbers), ordered
top-left, top-right, bottom-right, bottom-left as the frame shows them. `area`
is the fraction of the frame the sheet covers, `rectangularity` how much of the
bright region's hull its four corners take in (1 for a perfect
quadrilateral), and `edge_rms` the largest robust spread, in pixels, of an
edge's points around its fitted line.
"""
struct Page
    corners::NTuple{4, Vec2f}
    area::Float32
    rectangularity::Float32
    edge_rms::Float32
end

luminance(c::Real) = Float32(c)
luminance(c::Gray) = Float32(gray(c))
luminance(c::AbstractRGB) = 0.299f0 * Float32(red(c)) + 0.587f0 * Float32(green(c)) + 0.114f0 * Float32(blue(c))

"""
    whiteness(c) -> Float32

Bright and colourless: the darkest channel, minus twice the colour's
saturation. Neutral paper, even in shadow, keeps it; a wooden desk loses it to
its colour and a dark desk to its darkness.
"""
function whiteness(c::AbstractRGB)
    r, g, b = Float32(red(c)), Float32(green(c)), Float32(blue(c))
    lo = min(r, g, b); hi = max(r, g, b)
    clamp(lo - 2 * (hi - lo), 0f0, 1f0)
end
whiteness(c::Real) = Float32(c)

"""
    sample(img, x, y)

`img[x, y]` at a point between pixels, interpolated bilinearly; points outside
are clamped to the border.
"""
@inline function sample(img::AbstractMatrix, x::Real, y::Real)
    w, h = size(img)
    x = clamp(Float32(x), 1.0f0, Float32(w))
    y = clamp(Float32(y), 1.0f0, Float32(h))
    x0 = min(unsafe_trunc(Int, x), w)
    y0 = min(unsafe_trunc(Int, y), h)
    x1, y1 = min(x0 + 1, w), min(y0 + 1, h)
    fx, fy = x - x0, y - y0
    @inbounds begin
        a, b = float32(img[x0, y0]), float32(img[x1, y0])
        c, d = float32(img[x0, y1]), float32(img[x1, y1])
    end
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
end

float32(c::Real) = Float32(c)
float32(c::Gray) = Float32(gray(c))
float32(c::AbstractRGB) = RGB{Float32}(c)

cross2(a, b) = a[1] * b[2] - a[2] * b[1]
cross2(o, a, b) = cross2(a - o, b - o)
polygon_area(poly) = abs(sum(cross2(poly[i], poly[mod1(i + 1, length(poly))]) for i in eachindex(poly))) / 2

"""
    order_corners(quad) -> NTuple{4, Vec2f}

Top-left, top-right, bottom-right, bottom-left: clockwise on screen, starting at
the corner nearest the frame's origin.
"""
function order_corners(quad)
    c = sum(quad) / length(quad)
    sorted = sort(collect(quad); by = p -> atan(p[2] - c[2], p[1] - c[1]))
    first = argmin(p -> p[1] + p[2], sorted)
    k = findfirst(==(first), sorted)
    return ntuple(i -> sorted[mod1(k + i - 1, 4)], 4)
end

function intersect_lines((c1, d1), (c2, d2))
    t = cross2(c2 - c1, d2) / cross2(d1, d2)
    return c1 + t * d1
end

pack_n0f8(v::Float32) = reinterpret(N0f8, unsafe_trunc(UInt8, round(clamp(v, 0f0, 1f0) * 255f0)))

# ── Kernels ──────────────────────────────────────────────────────────────────

"""
    shrink!(out, src, params, w)

`src` averaged over f×f blocks into `out` (`w` wide), starting at pixel
`(x0, y0) + 1`: `params` holds `(f, x0, y0)`. The live view's preview, the
detector's input and the review's zoomed tiles all come from here.
"""
@kernel function shrink!(out, @Const(src), @Const(params), w::Int)
    i = @index(Global)
    @inbounds f = Int(params[1]); x0 = Int(params[2]); y0 = Int(params[3])
    x = mod(i - 1, w) + 1; y = (i - 1) ÷ w + 1
    r = 0f0; g = 0f0; b = 0f0
    for yy in (y0 + (y - 1) * f + 1):(y0 + y * f), xx in (x0 + (x - 1) * f + 1):(x0 + x * f)
        @inbounds c = src[xx, yy]
        r += red(c); g += green(c); b += blue(c)
    end
    n = Float32(f * f)
    @inbounds out[i] = RGB{N0f8}(pack_n0f8(r / n), pack_n0f8(g / n), pack_n0f8(b / n))
end

# Luminance for the trigger's thumbnail, whiteness for finding the sheet.
@kernel function detect_features!(lum, white, @Const(rgb))
    i = @index(Global)
    @inbounds c = RGB{Float32}(rgb[i])
    @inbounds begin
        lum[i] = luminance(c)
        white[i] = whiteness(c)
    end
end

const DETECT_HIST_GROUPS = 64
@kernel function detect_hist_clear!(hist)
    i = @index(Global)
    @inbounds hist[i] = Int32(0)
end
# Spread over groups so the atomics of neighbouring pixels rarely collide.
@kernel function detect_hist!(hist, @Const(white))
    i = @index(Global)
    @inbounds bin = clamp(unsafe_trunc(Int, white[i] * 256f0) + 1, 1, 256)
    KA.@atomic hist[bin, mod(i - 1, DETECT_HIST_GROUPS) + 1] += Int32(1)
end

# Otsu's threshold, in one thread over 256 bins. Too little contrast between
# the two classes means there is no sheet: the threshold is then above 1.
@kernel function detect_otsu!(threshold, @Const(hist), min_contrast::Float32)
    i = @index(Global)
    total = 0f0; sum_all = 0f0
    for bin in 1:256
        c = 0f0
        for g in 1:DETECT_HIST_GROUPS
            @inbounds c += hist[bin, g]
        end
        total += c; sum_all += c * (bin - 0.5f0) / 256f0
    end
    wb = 0f0; sb = 0f0; best = -1f0; thr = 2f0; mb = 0f0; mf = 0f0
    for bin in 1:255
        c = 0f0
        for g in 1:DETECT_HIST_GROUPS
            @inbounds c += hist[bin, g]
        end
        wb += c; sb += c * (bin - 0.5f0) / 256f0
        wf = total - wb
        if wb > 0f0 && wf > 0f0
            between = wb * wf * (sb / wb - (sum_all - sb) / wf)^2
            if between > best
                best = between; thr = bin / 256f0; mb = sb / wb; mf = (sum_all - sb) / wf
            end
        end
    end
    @inbounds threshold[1] = mf - mb >= min_contrast ? thr : 2f0
end

@kernel function detect_mask!(mask, @Const(white), @Const(threshold))
    i = @index(Global)
    @inbounds mask[i] = white[i] >= threshold[1] ? Int32(1) : Int32(0)
end

# Opening with a (2r+1)² square: erode, then dilate. Outside the frame counts
# as neither, so a region may touch the border.
@kernel function detect_morph!(out, @Const(mask), w::Int, h::Int, r::Int, dilate::Bool)
    i = @index(Global)
    x = mod(i - 1, w) + 1; y = (i - 1) ÷ w + 1
    v = dilate ? Int32(0) : Int32(1)
    for dy in -r:r, dx in -r:r
        xx = x + dx; yy = y + dy
        if 1 <= xx <= w && 1 <= yy <= h
            @inbounds m = mask[xx + (yy - 1) * w]
            v = dilate ? max(v, m) : min(v, m)
        end
    end
    @inbounds out[i] = v
end

@kernel function detect_cc_init!(parents, count, extreme, counter, @Const(mask))
    k = @index(Global)
    @inbounds begin
        parents[k] = mask[k] == Int32(1) ? Int32(k) : Int32(0)
        count[k] = Int32(0)
        for d in 1:16
            extreme[d, k] = UInt32(0)
        end
        k == 1 && (counter[1] = Int32(0))
    end
end
@kernel function detect_cc_merge!(parents, @Const(mask), w::Int)
    k = @index(Global)
    x = mod(k - 1, w) + 1; y = (k - 1) ÷ w + 1
    if @inbounds mask[k] == Int32(1)
        if x > 1 && (@inbounds mask[k - 1] == Int32(1))
            page_cc_join!(parents, Int32(k), Int32(k - 1))
        end
        if y > 1
            for dx in -1:1
                j = k - w + dx
                if 1 <= x + dx <= w && (@inbounds mask[j] == Int32(1))
                    page_cc_join!(parents, Int32(k), Int32(j))
                end
            end
        end
    end
end
@inline function detect_root(parents, k::Int32)
    while (@inbounds parents[k]) != k
        @inbounds k = parents[k]
    end
    k
end
# Size and the extreme pixel in 16 directions of every region. A key holds the
# projection on a direction above the pixel's index, so one atomic maximum
# finds the pixel, ties going to the later one.
@kernel function detect_cc_stats!(count, extreme, @Const(parents), w::Int)
    k = @index(Global)
    if @inbounds parents[k] != Int32(0)
        root = detect_root(parents, Int32(k))
        x = Float32(mod(k - 1, w) + 1); y = Float32((k - 1) ÷ w + 1)
        KA.@atomic count[root] += Int32(1)
        for d in 1:16
            s, c = sincos(Float32(2π) * (d - 1) / 16f0)
            p = unsafe_trunc(Int32, round(x * c + y * s)) + Int32(2048)
            key = (UInt32(p) << 20) | UInt32(k)
            KA.@atomic max(extreme[d, root], key)
        end
    end
end
@kernel function detect_cc_compact!(list, counter, @Const(count), @Const(extreme), min_count::Int32, capacity::Int)
    k = @index(Global)
    @inbounds c = count[k]
    if c >= min_count
        slot = KA.@atomic counter[1] += Int32(1)
        if slot <= capacity
            @inbounds begin
                list[1, slot] = UInt32(k); list[2, slot] = UInt32(c)
                for d in 1:16
                    list[2 + d, slot] = extreme[d, k]
                end
            end
        end
    end
end

# Each row's leftmost and rightmost pixel of the candidate regions.
@kernel function detect_spans_clear!(spans)
    i = @index(Global)
    @inbounds spans[i] = isodd(i) ? typemax(Int32) : Int32(0)
end
@kernel function detect_spans!(spans, @Const(parents), @Const(roots), w::Int, candidates::Int)
    k = @index(Global)
    if @inbounds parents[k] != Int32(0)
        root = detect_root(parents, Int32(k))
        x = Int32(mod(k - 1, w) + 1); y = (k - 1) ÷ w + 1
        for c in 1:candidates
            if @inbounds roots[c] == root
                KA.@atomic min(spans[1, y, c], x)
                KA.@atomic max(spans[2, y, c], x)
            end
        end
    end
end

@inline function edge_profile(img, p::Vec2f, n::Vec2f, d::Vec2f, s::Float32)
    q = p + s * n
    # A few pixels along the edge, so one speck of dust does not move it.
    v = 0f0
    for o in -2:2
        r = q + Float32(o) * d
        v += whiteness(sample(img, r[1], r[2]))
    end
    v / 5f0
end
# Where each edge really is: along profiles across it, the outermost steep fall
# of whiteness, at its steepest point, to a fraction of a pixel. The quad is
# clockwise on screen, so outwards is to the left of a → b. NaN where a profile
# has no clear fall.
@kernel function detect_edges!(points, @Const(img), @Const(params), samples::Int)
    i = @index(Global)
    e = (i - 1) ÷ samples + 1; j = mod(i - 1, samples)
    next = mod1(e + 1, 4)
    @inbounds begin
        a = Vec2f(params[2 * e - 1], params[2 * e]); b = Vec2f(params[2 * next - 1], params[2 * next])
        search = params[9]; margin = params[10]; min_drop = params[11]
    end
    v = b - a
    d = v / sqrt(v[1] * v[1] + v[2] * v[2]); n = Vec2f(d[2], -d[1])
    p = a + (margin + (1f0 - 2margin) * Float32(j) / Float32(samples - 1)) * (b - a)
    step = 0.5f0
    K = unsafe_trunc(Int, search / step)
    # The fall over 2 pixels: a crumpled sheet's edge can be soft over 20.
    fall(k) = edge_profile(img, p, n, d, (k + 2) * step) - edge_profile(img, p, n, d, (k - 2) * step)
    # The steepest fall along the profile sets the scale ...
    best = 0f0
    for k in (-K + 2):(K - 2)
        best = min(best, fall(k))
    end
    # ... and the edge is the outermost fall at least half as steep: a fold or
    # a shadow on the sheet falls as steeply, but always inside the edge.
    # Walking inwards: find that fall, then follow it to its steepest point.
    kbest = 0; gbest = 0f0; found = false
    for k in (K - 2):-1:(-K + 2)
        g = fall(k)
        if !found
            g <= 0.5f0 * best && (found = true; kbest = k; gbest = g)
        elseif g < gbest
            kbest = k; gbest = g
        else
            break
        end
    end
    x = NaN32; y = NaN32
    if found && -K + 3 <= kbest <= K - 3
        # A clear step over ±3 pixels, however soft.
        drop = edge_profile(img, p, n, d, max(kbest - 6, -K) * step) - edge_profile(img, p, n, d, min(kbest + 6, K) * step)
        if drop >= min_drop
            gm = fall(kbest - 1); gp = fall(kbest + 1)
            denom = gm - 2gbest + gp
            δ = denom == 0f0 ? 0f0 : clamp(0.5f0 * (gm - gp) / denom, -0.5f0, 0.5f0)
            q = p + (kbest + δ) * step * n
            x = q[1]; y = q[2]
        end
    end
    @inbounds begin points[1, i] = x; points[2, i] = y; end
end

# Each thumbnail pixel is the mean of samples×samples points spread over its
# area, read bilinearly from the shrunk luminance.
@kernel function detect_thumbnail!(out, @Const(lum), @Const(H), tw::Int, samples::Int)
    i = @index(Global)
    u = Float32(mod(i - 1, tw) + 1); v = Float32((i - 1) ÷ tw + 1)
    s = 0f0
    for a in 1:samples, b in 1:samples
        x = u + (a - 0.5f0) / samples - 0.5f0
        y = v + (b - 0.5f0) / samples - 0.5f0
        @inbounds begin
            z = H[7] * x + H[8] * y + H[9]
            sx = (H[1] * x + H[2] * y + H[3]) / z
            sy = (H[4] * x + H[5] * y + H[6]) / z
        end
        s += sample(lum, sx, sy)
    end
    @inbounds out[i] = s / Float32(samples * samples)
end

# ── Host side ────────────────────────────────────────────────────────────────

"""
    PageDetector(; select = info -> true, detect_size = 800, thumbnail_size = (48, 68),
        thumbnail_samples = 6, samples = 64, min_area = 0.02, max_area = 0.98,
        min_rectangularity = 0.75, min_contrast = 0.15, min_drop = 0.05,
        max_spread = 4, border = 2, candidates = 5, opening = 2, coarse_search = 32)

The GPU side of [`detect!`](@ref): a Mantle device of its own, its buffers
for one frame size and the recorded passes. Create it, use it and `close` it on
one thread: Mantle submits from the thread that made the device. `select`
names the device, see `Mantle.Device`; the default takes the best GPU.

A sheet covers between `min_area` and `max_area` of the frame, its corners
take in at least `min_rectangularity` of its region's hull and the region's
rows fill as much, and it keeps `border` shrunk pixels clear of the frame's
edge. Each edge needs a whiteness fall of `min_drop` along half its `samples`
profiles, and its points may spread at most `max_spread` shrunk pixels around
the fitted line.
"""
mutable struct PageDetector{D}
    device::D
    detect_size::Int
    thumbnail_size::NTuple{2, Int}
    thumbnail_samples::Int
    samples::Int
    min_area::Float64
    max_area::Float64
    min_rectangularity::Float64
    min_contrast::Float32
    min_drop::Float32
    max_spread::Float32
    border::Int
    candidates::Int
    opening::Int
    coarse_search::Float32
    capacity::Int
    frame::NTuple{2, Int}
    factor::Int
    small::NTuple{2, Int}
    buffers::Dict{Symbol, Any}
    plans::Dict{Any, Any}
end

function PageDetector(; select = info -> true, detect_size::Int = 800, thumbnail_size::NTuple{2, Int} = (48, 68),
        thumbnail_samples::Int = 6, samples::Int = 64, min_area = 0.02, max_area = 0.98, min_rectangularity = 0.75,
        min_contrast = 0.15f0, min_drop = 0.05f0, max_spread = 4, border::Int = 2, candidates::Int = 5, opening::Int = 2, coarse_search = 32)
    device = Mantle.Device(select)
    PageDetector(device, detect_size, thumbnail_size, thumbnail_samples, samples, Float64(min_area), Float64(max_area),
        Float64(min_rectangularity), Float32(min_contrast), Float32(min_drop), Float32(max_spread), border, candidates, opening,
        Float32(coarse_search), 0, (0, 0), 1, (0, 0), Dict{Symbol, Any}(), Dict{Any, Any}())
end

function Base.close(d::PageDetector)
    Mantle.waitidle(d.device)
    foreach(Mantle.free!, values(d.plans)); empty!(d.plans)
    foreach(Mantle.free!, values(d.buffers)); empty!(d.buffers)
    d.frame = (0, 0)
    nothing
end

detect_buffer!(d::PageDetector, name, T, dims) = get!(() -> Mantle.Buffer(d.device, T, dims), d.buffers, name)

function detect_plan(f, d::PageDetector, key)
    get!(d.plans, key) do
        g = Mantle.Graph(d.device)
        f(g)
        Mantle.record!(Mantle.Plan(g))
    end
end

# Buffers and the per-frame pass for frames of `size(img)`.
function setup!(d::PageDetector, img::AbstractMatrix{RGB{N0f8}})
    size(img) == d.frame && return d
    close(d)
    W, H = size(img)
    f = max(1, round(Int, max(W, H) / d.detect_size))
    w, h = W ÷ f, H ÷ f
    n = w * h
    n < 2^20 || throw(ArgumentError("detect_size too large: shrunk frame needs fewer than 2^20 pixels"))
    d.factor, d.small = f, (w, h)
    b(name, T, dims) = detect_buffer!(d, name, T, dims)
    input = b(:input, RGB{N0f8}, (W, H)); frame = b(:frame, RGB{Float32}, (W, H))
    rgb = b(:rgb, RGB{N0f8}, (w, h)); lum = b(:lum, Float32, (w, h)); white = b(:white, Float32, (w, h))
    shrink_params = b(:shrink_params, Int32, (3,)); copyto!(shrink_params, Int32[f, 0, 0])
    hist = b(:hist, Int32, (256, DETECT_HIST_GROUPS)); threshold = b(:threshold, Float32, (1,))
    mask = b(:mask, Int32, (w, h)); eroded = b(:eroded, Int32, (w, h))
    parents = b(:parents, Int32, (n,)); count = b(:count, Int32, (n,))
    extreme = b(:extreme, UInt32, (16, n)); counter = b(:counter, Int32, (1,))
    min_count = Int32(ceil(d.min_area / 2 * n))
    # Enough slots for every region that can reach min_count.
    d.capacity = n ÷ Int(min_count) + 1
    list = b(:list, UInt32, (18, d.capacity))
    detect_plan(d, :frame) do g
        Mantle.dispatch!(g, page_copy!, (frame, input), W * H; name = "frame to float")
        Mantle.dispatch!(g, shrink!, (rgb, frame, shrink_params, w), n; name = "shrink")
        Mantle.dispatch!(g, detect_features!, (lum, white, rgb), n; name = "whiteness")
        Mantle.dispatch!(g, detect_hist_clear!, (hist,), length(hist); name = "clear histogram")
        Mantle.dispatch!(g, detect_hist!, (hist, white), n; name = "whiteness histogram")
        Mantle.dispatch!(g, detect_otsu!, (threshold, hist, d.min_contrast), 1; name = "Otsu threshold")
        Mantle.dispatch!(g, detect_mask!, (mask, white, threshold), n; name = "paper mask")
        Mantle.dispatch!(g, detect_morph!, (eroded, mask, w, h, d.opening, false), n; name = "erode")
        Mantle.dispatch!(g, detect_morph!, (mask, eroded, w, h, d.opening, true), n; name = "dilate")
        Mantle.dispatch!(g, detect_cc_init!, (parents, count, extreme, counter, mask), n; name = "regions init")
        Mantle.dispatch!(g, detect_cc_merge!, (parents, mask, w), n; name = "regions union")
        Mantle.dispatch!(g, detect_cc_stats!, (count, extreme, parents, w), n; name = "region statistics")
        Mantle.dispatch!(g, detect_cc_compact!, (list, counter, count, extreme, min_count, d.capacity), n; name = "large regions")
    end
    roots = b(:roots, Int32, (d.candidates,)); spans = b(:spans, Int32, (2, h, d.candidates))
    detect_plan(d, :spans) do g
        Mantle.dispatch!(g, detect_spans_clear!, (spans,), length(spans); name = "clear spans")
        Mantle.dispatch!(g, detect_spans!, (spans, parents, roots, w, d.candidates), n; name = "row spans")
    end
    # The same edge measurement on two images: the shrunk whiteness, with a
    # wide search around the region's outline, and then the full frame.
    for (scale, image) in ((:small, white), (:full, frame))
        params = b(Symbol(:edge_params_, scale), Float32, (11,))
        points = b(Symbol(:points_, scale), Float32, (2, 4d.samples))
        detect_plan(d, scale) do g
            Mantle.dispatch!(g, detect_edges!, (points, image, params, d.samples), 4d.samples; name = "edge profiles $scale")
        end
    end
    tw, th = d.thumbnail_size
    homography = b(:homography, Float32, (9,)); thumb = b(:thumbnail, Float32, (tw, th))
    detect_plan(d, :thumbnail) do g
        Mantle.dispatch!(g, detect_thumbnail!, (thumb, lum, homography, tw, d.thumbnail_samples), tw * th; name = "thumbnail")
    end
    d.frame = (W, H)
    return d
end

"""
    upload!(detector, img) -> detector

Puts the frame on the GPU and runs the per-frame pass: shrink, threshold and
regions. [`detect!`](@ref) does this first.
"""
function upload!(d::PageDetector, img::AbstractMatrix{RGB{N0f8}})
    setup!(d, img)
    copyto!(d.buffers[:input], img)
    Mantle.run!(d.plans[:frame])
    return d
end

# Rough quadrilaterals of the largest regions, in shrunk coordinates, best first.
function rough_quads(d::PageDetector)
    w, h = d.small
    counter = zeros(Int32, 1); copyto!(counter, d.buffers[:counter])
    found = Int(counter[1])
    found == 0 && return Tuple{NTuple{4, Vec2f}, Float32}[]
    list = zeros(UInt32, 18, d.capacity); copyto!(list, d.buffers[:list])
    order = first(sort(1:found; by = s -> list[2, s], rev = true), d.candidates)
    roots = zeros(Int32, d.candidates)
    for (c, s) in enumerate(order)
        roots[c] = Int32(list[1, s])
    end
    copyto!(d.buffers[:roots], roots)
    Mantle.run!(d.plans[:spans])
    spans = zeros(Int32, 2, h, d.candidates); copyto!(spans, d.buffers[:spans])
    quads = Tuple{NTuple{4, Vec2f}, Float32}[]
    for (c, s) in enumerate(order)
        # Pixel centres of the extreme pixels: a convex polygon inside the hull.
        hull = [begin
                    k = Int(list[2 + dir, s] & 0x000fffff)
                    Vec2f(mod(k - 1, w) + 1, (k - 1) ÷ w + 1)
                end for dir in 1:16]
        hull_area = polygon_area(hull)
        hull_area > 0 || continue
        best, quad = 0f0, nothing
        for i in 1:13, j in (i + 1):14, k in (j + 1):15, l in (k + 1):16
            a = Float32(polygon_area((hull[i], hull[j], hull[k], hull[l])))
            a > best && ((best, quad) = (a, (hull[i], hull[j], hull[k], hull[l])))
        end
        quad === nothing && continue
        rows = sum(Float64(max(0, spans[2, y, c] - spans[1, y, c] + 1)) for y in 1:h)
        area = best / (w * h)
        rect = best / hull_area
        d.min_area <= area <= d.max_area || continue
        (rect >= d.min_rectangularity && rows / hull_area >= d.min_rectangularity) || continue
        any(p -> p[1] <= d.border || p[2] <= d.border || p[1] > w - d.border || p[2] > h - d.border, quad) && continue
        push!(quads, (order_corners(quad), Float32(rect)))
    end
    return quads
end

"""
    fit_line(points; iterations = 8) -> (centre, direction, spread)

A total least squares line through `points` with Huber weights: points further
than 1.5 robust spreads from the line count less, smoothly, so the line does
not jump when single points change. `spread` is the median absolute residual
scaled to a standard deviation.
"""
function fit_line(points::AbstractVector{Vec2f}; iterations::Int = 8)
    weights = ones(Float32, length(points))
    c, dir, spread = Vec2f(0), Vec2f(1, 0), Inf32
    for _ in 1:iterations
        total = sum(weights)
        c = sum(weights .* points) / total
        sxx = sum(weights[i] * (points[i][1] - c[1])^2 for i in eachindex(points))
        syy = sum(weights[i] * (points[i][2] - c[2])^2 for i in eachindex(points))
        sxy = sum(weights[i] * (points[i][1] - c[1]) * (points[i][2] - c[2]) for i in eachindex(points))
        θ = atan(2sxy, sxx - syy) / 2
        dir = Vec2f(cos(θ), sin(θ))
        res = [abs(cross2(dir, p - c)) for p in points]
        spread = 1.4826f0 * sort(res)[cld(length(res), 2)]
        k = max(1.5f0 * spread, 0.5f0)
        weights .= min.(1f0, k ./ max.(res, eps(Float32)))
    end
    return c, dir, spread
end

"""
    refine(detector, scale, quad, search; margin = 0.08) -> (corners, spread) or nothing

The four edges of `quad` measured again, each within `search` pixels of where
`quad` has it, in the shrunk whiteness (`scale = :small`) or the full frame
(`:full`), in that image's pixels. The corners are where the edges' lines
meet; `spread` is the worst edge's. This is also the real test of a sheet:
each edge must be a clear fall in whiteness along half its profiles, and its
points must lie within `max_spread` shrunk pixels of a line.
"""
function refine(d::PageDetector, scale::Symbol, quad::NTuple{4, Vec2f}, search::Real; margin = 0.08f0)
    params = Float32[quad[1]..., quad[2]..., quad[3]..., quad[4]..., search, margin, d.min_drop]
    copyto!(d.buffers[Symbol(:edge_params_, scale)], params)
    Mantle.run!(d.plans[scale])
    raw = zeros(Float32, 2, 4d.samples); copyto!(raw, d.buffers[Symbol(:points_, scale)])
    lines = map(1:4) do e
        pts = [Vec2f(raw[1, i], raw[2, i]) for i in ((e - 1) * d.samples + 1):(e * d.samples) if !isnan(raw[1, i])]
        length(pts) >= d.samples ÷ 2 || return nothing
        fit_line(pts)
    end
    any(isnothing, lines) && return nothing
    spread = maximum(l -> l[3], lines)
    spread <= d.max_spread * (scale === :full ? d.factor : 1) || return nothing
    corners = ntuple(k -> intersect_lines(lines[mod1(k - 1, 4)][1:2], lines[k][1:2]), 4)
    all(p -> all(isfinite, p), corners) || return nothing
    return corners, spread
end

"""
    find_page(detector, img) -> Union{Page, Nothing}

The sheet in `img[x, y]`, or `nothing` when there is none. See
[`PageDetector`](@ref) for what counts as a sheet.
"""
function find_page(d::PageDetector, img::AbstractMatrix{RGB{N0f8}})
    upload!(d, img)
    return find_page(d)
end

# The sheet in the frame `upload!` put on the GPU last.
function find_page(d::PageDetector)
    f = d.factor; W, H = d.frame
    for (quad, rect) in rough_quads(d)
        # A shadow on the sheet can bite into its region: the outline may be
        # off by tens of shrunk pixels where the shadow is.
        coarse = refine(d, :small, quad, d.coarse_search)
        coarse === nothing && continue
        full = map(p -> (p .- 0.5f0) .* f .+ 0.5f0, coarse[1])
        first_pass = refine(d, :full, full, max(2f + 2, 3coarse[2] * f))
        first_pass === nothing && continue
        # Again along the measured edges: the samples sit where the edges are,
        # whatever the earlier outlines were.
        second = refine(d, :full, first_pass[1], clamp(4first_pass[2] + 4, 6, 3f + 2))
        second === nothing && continue
        corners, spread = second
        all(p -> 0.5f0 <= p[1] <= W + 0.5f0 && 0.5f0 <= p[2] <= H + 0.5f0, corners) || continue
        all(k -> cross2(corners[k], corners[mod1(k + 1, 4)], corners[mod1(k + 2, 4)]) > 0, 1:4) || continue
        return Page(corners, Float32(polygon_area(corners) / (W * H)), rect, spread)
    end
    return nothing
end

"""
    thumbnail(detector, page) -> Matrix{Float32}

The sheet in the frame `upload!` put on the GPU last, warped flat into a tiny
grey image and normalized to mean 0 and unit spread. A contrast floor keeps
sensor noise on blank pages from being amplified into large changes, and
global brightness changes are removed. Each pixel averages
`thumbnail_samples`² points over its area: text lines are about two thumbnail
pixels apart, and fewer point samples alias them, so a few pixels of corner
jitter would look like a different sheet.
"""
function thumbnail(d::PageDetector, page::Page)
    tw, th = d.thumbnail_size; f = d.factor
    target = (Vec2f(0.5, 0.5), Vec2f(tw + 0.5, 0.5), Vec2f(tw + 0.5, th + 0.5), Vec2f(0.5, th + 0.5))
    H = homography(target, map(p -> (p .- 0.5f0) ./ f .+ 0.5f0, portrait(page.corners)))
    copyto!(d.buffers[:homography], Float32[H[i, j] for i in 1:3 for j in 1:3])
    Mantle.run!(d.plans[:thumbnail])
    t = zeros(Float32, tw, th); copyto!(t, d.buffers[:thumbnail])
    t .-= sum(t) / length(t)
    s = sqrt(sum(abs2, t) / length(t))
    return t ./ max(s, 0.1f0)
end

thumbnail(d::PageDetector, img::AbstractMatrix{RGB{N0f8}}, page::Page) = thumbnail(upload!(d, img), page)

"""
    Detection

One frame looked at: the sheet in it or `nothing`, the sheet's thumbnail for
the [`Trigger`](@ref), and `preview`, the frame shrunk by `scale` (x first).
"""
struct Detection
    page::Union{Page, Nothing}
    thumbnail::Union{Matrix{Float32}, Nothing}
    preview::Matrix{RGB{N0f8}}
    scale::Int
end

"""
    detect!(detector, img) -> Detection

Everything the live view needs from one frame, from one upload to the GPU.
"""
function detect!(d::PageDetector, img::AbstractMatrix{RGB{N0f8}})
    upload!(d, img)
    page = find_page(d)
    thumb = page === nothing ? nothing : thumbnail(d, page)
    preview = Matrix{RGB{N0f8}}(undef, d.small)
    copyto!(preview, d.buffers[:rgb])
    return Detection(page, thumb, preview, d.factor)
end
