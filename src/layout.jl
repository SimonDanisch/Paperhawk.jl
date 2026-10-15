# How a page is set, beyond its words: where each text line's ink sits, how
# large and in which colour, and the ink that is not text (logos, signatures,
# stamps, rules). Measured on the GPU from the cleaned, upright page right
# after its words are read, and kept in the draft beside them, so the archive's
# reconstructions are drawn from the draft alone and follow corrected words.
#
# Coordinates are page pixels as edges: pixel `x` spans `x - 1` to `x`, the
# convention of the OCR's boxes, and of SVG.

"""
    LineStyle

One text line as it is set: its box from the OCR (`x0, y0, x1, y1`), the left
and right edge of its ink, the top of its ink, its baseline and the bottom of
its descenders, its x-height and font size (the em) in pixels, the ink's colour
and its stroke width in pixels, and whether it is part of a picture rather than
text (see [`isfigureline`](@ref)).
"""
struct LineStyle
    box::NTuple{4, Float32}
    left::Float32
    right::Float32
    top::Float32
    baseline::Float32
    bottom::Float32
    xheight::Float32
    size::Float32
    color::NTuple{3, UInt8}
    stroke::Float32
    figure::Bool
end

"""
    PageLayout

A page's size in pixels, the style of each of its text lines in reading order,
and the boxes (`x0, y0, x1, y1`) of ink that is not text.
"""
struct PageLayout
    size::NTuple{2, Int}
    lines::Vector{LineStyle}
    figures::Vector{NTuple{4, Float32}}
end

PageLayout(dims::NTuple{2, Int}) = PageLayout(dims, LineStyle[], NTuple{4, Float32}[])

JSON3.StructTypes.StructType(::Type{LineStyle}) = JSON3.StructTypes.Struct()
JSON3.StructTypes.StructType(::Type{PageLayout}) = JSON3.StructTypes.Struct()

"""A layout read back from a draft's JSON."""
function PageLayout(d::AbstractDict)
    line(l) = LineStyle(Tuple(Float32.(l["box"])), l["left"], l["right"], l["top"], l["baseline"], l["bottom"],
                        l["xheight"], l["size"], Tuple(UInt8.(l["color"])), l["stroke"], l["figure"])
    return PageLayout(Tuple(Int.(d["size"])), line.(d["lines"]), [Tuple(Float32.(f)) for f in d["figures"]])
end

isink(c::Gray{Bool}) = !gray(c)

median(v) = (s = sort(v); n = length(s); isodd(n) ? s[cld(n, 2)] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)

@kernel function layout_inkmask!(mask, @Const(white))
    i = @index(Global)
    @inbounds mask[i] = gray(white[i]) ? Int32(0) : Int32(1)
end

# The pixels a box of edges covers, as an inclusive pixel range for the GPU.
pixelbox((x0, y0, x1, y1), (w, h), f = 1) =
    Vec{4, Int32}(clamp(floor(Int, x0 / f) + 1, 1, w), clamp(floor(Int, y0 / f) + 1, 1, h),
                  clamp(ceil(Int, x1 / f), 1, w), clamp(ceil(Int, y1 / f), 1, h))

"""
    layout!(s, page, lines; capacity = 512, rows = 384, shrink = 4, merge = 2) -> PageLayout

The layout of `page`, an upright `PPOCRRunner.PageInput`, whose text `lines`
the OCR just read. On the GPU: Sauvola's threshold marks the ink; per line, ink
per row, its runs, its extent and its colour (`GPUFiltering.boxrows!`). The figures come
from the page shrunk `shrink` times: its ink with the text lines erased,
dilated by `merge` so a signature's strokes join, as connected components. The
first `capacity` lines are measured, `rows` rows of each.
"""
function layout!(s::PageWorkspace, page, lines; capacity::Int = 512, rows::Int = 384, shrink::Int = 4, merge::Int = 2)
    dims = size(page); w, h = dims
    small = (w ÷ shrink, h ÷ shrink)
    n = min(length(lines), capacity)
    height = n == 0 ? 0.0f0 : median([l.box[4] - l.box[2] for l in lines])
    figure = [isfigureline(lines[k], height) for k in 1:n]
    boxes = array!(s, :layout_boxes, Vec{4, Int32}, (capacity,))
    smallboxes = array!(s, :layout_small_boxes, Vec{4, Int32}, (capacity,))
    count = array!(s, :layout_count, Int32, (1,))
    host = fill(Vec{4, Int32}(1, 1, 1, 1), capacity)
    for k in 1:n
        host[k] = pixelbox(lines[k].box, dims)
    end
    copyto!(boxes, host)
    # Only text is erased before looking for figures: a signature or a stamp
    # the recogniser read as letters stays a picture.
    text = findall(!, figure)
    for (k, j) in enumerate(text)
        host[k] = pixelbox(lines[j].box, small, shrink)
    end
    copyto!(smallboxes, host)
    copyto!(count, Int32[n])
    textcount = array!(s, :layout_text_count, Int32, (1,))
    copyto!(textcount, Int32[length(text)])
    stats = array!(s, :layout_rows, GF.RowStats, (rows, capacity))
    figures = array!(s, :layout_figures, Int32, (5, 256))
    figcount = array!(s, :layout_figure_count, Int32, (1,))
    run!(s, (:layout, dims)) do g
        pixels = Mantle.storage(page.pixels)
        white = array!(s, :layout_white, Gray{Bool}, dims)
        tmp = ntuple(i -> array!(s, (:sauvola, i), Float32, dims), 3)
        GF.sauvola!(g, white, pixels, 31, 0.2, 0.5, tmp)
        GF.boxrows!(g, stats, pixels, white, boxes, isink, count)
        rgb = array!(s, :layout_small_rgb, RGB{Float32}, small)
        smallwhite = array!(s, :layout_small_white, Gray{Bool}, small)
        smalltmp = ntuple(i -> array!(s, (:layout_small_sauvola, i), Float32, small), 3)
        mask = array!(s, :layout_mask, Int32, small)
        dilated = array!(s, :layout_dilate_tmp, Int32, small)
        labels = array!(s, :layout_labels, Int32, small)
        componentstats = array!(s, :layout_component_stats, Int32, (5, prod(small)))
        GF.areadownscale!(g, rgb, pixels, GF.Blocks(shrink))
        GF.sauvola!(g, smallwhite, rgb, 15, 0.2, 0.5, smalltmp)
        Mantle.dispatch!(g, layout_inkmask!, (mask, smallwhite), prod(small); name = "ink mask")
        GF.fillboxes!(g, mask, smallboxes, Int32(0), textcount)
        GF.dilate!(g, mask, mask, merge, dilated)
        GF.components!(g, labels, mask, !iszero)
        GF.componentboxes!(g, figures, figcount, labels, 12, componentstats)
    end
    measured = Matrix{GF.RowStats}(undef, rows, n)
    n > 0 && copyto!(measured, 1, stats, 1, rows * n)
    styles = [linestyle(lines[k].box, Int(pixelbox(lines[k].box, dims)[2]), view(measured, :, k), figure[k]) for k in 1:n]
    found = only(Array(figcount))
    list = Matrix{Int32}(undef, 5, 256); copyto!(list, figures)
    figs = [figurebox(list[:, j], shrink, merge, dims) for j in 1:min(found, 256)]
    figs = unique(filter(f -> isfigure(f, dims), figs))
    # A stamp's inner ring is part of the stamp.
    outer = filter(f -> !any(g -> g != f && encloses(g, f), figs), figs)
    return PageLayout(dims, styles, outer)
end

encloses((x0, y0, x1, y1), (a0, b0, a1, b1)) = x0 <= a0 && y0 <= b0 && a1 <= x1 && b1 <= y1

"""
    linestyle(box, firstrow, rows, figure) -> LineStyle

A line's style from its ink per row (`GPUFiltering.RowStats`, the first row
being page row `firstrow`): the rows holding at least half the busiest row's
ink are the x-height band, from its top to the baseline; any ink row bounds the
ascenders, the descenders and the ink's left and right edge. The em is the
ascent over 0.72 (the ascender of common text faces), or the x-height over 0.52
for a line without ascenders or capitals. Without ink, the style follows from
the box.
"""
function linestyle(box, firstrow::Int, rows::AbstractVector{GF.RowStats}, figure::Bool)
    counts = [r.count for r in rows]
    peak = maximum(counts; init = Int32(0))
    peak == 0 && return boxstyle(box, figure)
    ink = findall(>=(max(1, peak ÷ 20)), counts)
    core = findall(>=(peak / 2), counts)
    edge(r) = Float32(firstrow + r - 2)
    top, bottom = edge(first(ink)), edge(last(ink) + 1)
    xtop, baseline = edge(first(core)), edge(last(core) + 1)
    inked = filter(r -> r.count > 0, view(rows, ink))
    left = Float32(minimum(r -> r.first, inked) - 1)
    right = Float32(maximum(r -> r.last, inked))
    xheight = baseline - xtop
    ascent = baseline - top
    em = ascent > 1.25f0 * xheight ? ascent / 0.72f0 : xheight / 0.52f0
    total = sum(r -> r.count, inked)
    c = reduce(+, (r.sum for r in inked); init = RGB{Float32}(0, 0, 0))
    color = map(v -> round(UInt8, clamp(v / total, 0, 1) * 255), (c.r, c.g, c.b))
    stroke = Float32(sum(r -> r.count, view(rows, core)) / max(1, sum(r -> r.runs, view(rows, core))))
    return LineStyle(box, left, right, top, baseline, bottom, xheight, em, color, stroke, figure)
end

"""
    boxstyle(box, figure = false) -> LineStyle

A line's style guessed from its box alone, for a line without measured ink.
The proportions are the medians of lines of 10 pt text measured at 300 dpi:
the ink starts 0.14 box heights inside the box and ends 0.13 before its end,
its top is at 0.18 and its baseline at 0.77, and the em is 0.81 box heights.
"""
function boxstyle((x0, y0, x1, y1), figure::Bool = false)
    h = y1 - y0
    return LineStyle((x0, y0, x1, y1), x0 + 0.14f0h, x1 - 0.13f0h, y0 + 0.18f0h, y0 + 0.77f0h, y1 - 0.06f0h,
                     0.42f0h, 0.81f0h, (0x00, 0x00, 0x00), 0.03f0h, figure)
end

"""
    isfigureline(line, height) -> Bool

Whether a line the recogniser read is a picture rather than text: read with
less than 75% confidence (a signature read as letters), or at most three
characters on a box over four times the page's median line height (a stamp's
ring read as "O"). `height` is that median.
"""
isfigureline(l::PPOCRRunner.TextLine, height) =
    l.score < 0.75f0 || (l.box[4] - l.box[2] > 4height && length(l.text) <= 3)

# A component's box back at the page's resolution, without the dilation.
function figurebox(c, shrink, merge, (w, h))
    x0, y0, x1, y1 = c[1] + merge, c[2] + merge, c[3] - merge, c[4] - merge
    return (Float32(clamp((x0 - 1) * shrink, 0, w)), Float32(clamp((y0 - 1) * shrink, 0, h)),
            Float32(clamp(x1 * shrink, 0, w)), Float32(clamp(y1 * shrink, 0, h)))
end

# Specks are not figures; long thin marks are (rules), and so is anything of
# some extent in both directions.
function isfigure((x0, y0, x1, y1), (w, h))
    bw, bh = x1 - x0, y1 - y0
    (bw <= 0 || bh <= 0) && return false
    return max(bw, bh) >= min(w, h) / 12 || min(bw, bh) >= min(w, h) / 40
end
