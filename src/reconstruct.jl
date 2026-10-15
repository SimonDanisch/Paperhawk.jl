# A scanned document written out again: as Markdown for a quick look and for
# search, and as a vector reconstruction (HTML with one SVG per page) whose text
# sits where the page has it, at its size and in its colour, with the ink that
# is not text (logos, signatures, stamps, rules) cut out of the cleaned page.
# Both are drawn from the reviewed words and the measured layout alone.

"""
    ScannedPage(image, words, layout, dpi)

A page as the archive writes it out: the cleaned image `img[x, y]`, the
reviewed words, the [`PageLayout`](@ref) measured with them (`nothing` for a
draft from before layouts were measured) and the resolution.
"""
struct ScannedPage{M <: AbstractMatrix}
    image::M
    words::Vector{Word}
    layout::Union{Nothing, PageLayout}
    dpi::Int
end

"""
    RenderLine

A text line ready to write: its words and its style.
"""
struct RenderLine
    words::Vector{Word}
    style::LineStyle
end

linetext(l::RenderLine) = join((w.text for w in l.words), ' ')

"""
    renderlines(page) -> Vector{RenderLine}

The page's words grouped into its measured lines, in reading order. A word
belongs to the line whose box it came from: same top and height, and inside
its span. Without a layout, each run of words sharing a line box is a line,
styled from the box alone.
"""
function renderlines(p::ScannedPage)
    p.layout === nothing && return [RenderLine(ws, boxstyle(runbox(ws))) for ws in wordruns(p.words)]
    lines = [RenderLine(Word[], s) for s in p.layout.lines]
    for w in p.words
        k = findfirst(l -> belongs(w, l.style.box), lines)
        k === nothing ? push!(lines, RenderLine([w], boxstyle(runbox([w])))) : push!(lines[k].words, w)
    end
    return filter(l -> !isempty(l.words), lines)
end

belongs(w::Word, (x0, y0, x1, y1)) =
    w.line_y == round(Int, y0) && w.line_height == max(1, round(Int, y1 - y0)) && x0 - 2 <= w.x <= x1

function wordruns(words::AbstractVector{Word})
    runs = Vector{Vector{Word}}()
    for w in words
        if !isempty(runs) && (last(runs)[end].line_y, last(runs)[end].line_height) == (w.line_y, w.line_height)
            push!(last(runs), w)
        else
            push!(runs, [w])
        end
    end
    return runs
end

# The line box a run of words came from, as far as the words tell.
runbox(ws) = (Float32(first(ws).x), Float32(first(ws).line_y), Float32(last(ws).x + last(ws).width),
              Float32(first(ws).line_y + first(ws).line_height))

# ── Markdown ────────────────────────────────────────────────────────────────

mdescape(s::AbstractString) = replace(s, r"([\\`*_\[\]<>])" => s"\\\1")

"""
    markdown(pages; title = "") -> String

The document as Markdown: lines in reading order, a blank line where the
vertical gap is larger than one and a half line pitches, lines set at 1.3 times
the body size or more as headings (`#` from 1.8 times), pages separated by a
rule. Lines of one paragraph stay on lines of their own, which Markdown reads
as one paragraph.
"""
function markdown(pages::AbstractVector{<:ScannedPage}; title::AbstractString = "")
    io = IOBuffer()
    isempty(title) || print(io, "# ", mdescape(title), "\n\n")
    for (k, p) in enumerate(pages)
        k > 1 && print(io, "\n---\n\n")
        # A signature or a stamp read as letters is not text to show.
        lines = filter(l -> !l.style.figure, renderlines(p))
        isempty(lines) && continue
        body = median([l.style.size for l in lines for _ in l.words])
        pitch = linepitch(lines, body)
        previous = nothing
        for l in lines
            ratio = l.style.size / body
            heading = ratio >= 1.8f0 ? "# " : ratio >= 1.3f0 ? "## " : ""
            if previous !== nothing
                gap = l.style.baseline - previous.style.baseline
                newblock = !isempty(heading) || previous.style.size / body >= 1.3f0 || gap > 1.5f0 * pitch || gap < -0.5f0 * pitch
                print(io, newblock ? "\n\n" : "\n")
            end
            print(io, heading, mdescape(linetext(l)))
            previous = l
        end
        print(io, "\n")
    end
    return String(take!(io))
end

# The usual distance between the baselines of consecutive lines, or 1.2 ems.
function linepitch(lines, body)
    gaps = Float32[]
    for (a, b) in zip(lines, Iterators.drop(lines, 1))
        g = b.style.baseline - a.style.baseline
        0.5f0 * body < g < 3 * body && push!(gaps, g)
    end
    return isempty(gaps) ? 1.2f0 * body : median(gaps)
end


# ── Vector reconstruction ──────────────────────────────────────────────────

xmlescape(s::AbstractString) = replace(s, '&' => "&amp;", '<' => "&lt;", '>' => "&gt;", '"' => "&quot;")
num(x) = string(round(Float64(x); digits = 1))
hexcolor((r, g, b)) = "#" * string(r; base = 16, pad = 2) * string(g; base = 16, pad = 2) * string(b; base = 16, pad = 2)

"""
    segments(line) -> [(left, right, words)]

A line's words split where two are further apart than 1.2 ems: a date set
against the right margin, a column. Each segment is set as one run of text from
`left` to `right`. Its outer ends are the line's ink; inside a line the ends
come from the words, widened by a quarter em, since the recogniser's word
extents run short by about half a character.
"""
function segments(l::RenderLine)
    em = l.style.size
    groups = [[first(l.words)]]
    for (a, b) in zip(l.words, Iterators.drop(l.words, 1))
        b.x - (a.x + a.width) > 1.2f0 * em ? push!(groups, [b]) : push!(last(groups), b)
    end
    return map(enumerate(groups)) do (k, ws)
        left = k == 1 ? l.style.left : first(ws).x - 0.25f0 * em
        right = k == length(groups) ? l.style.right : last(ws).x + last(ws).width + 0.25f0 * em
        (Float32(left), Float32(max(right, left + 1)), ws)
    end
end

"""
    pagesvg(page) -> String

One page as SVG in page pixels, sized for print by its resolution: the figures
as PNG cut-outs of the cleaned page, then each line's text on its baseline, in
its size and colour, a run per [`segments`](@ref) stretched to the extent the
page gives it (`textLength`), so the font only has to be close. Text inside a
figure is part of its picture and is drawn invisible, so it can still be found
and selected; so is a line that is itself part of a picture.
"""
function pagesvg(p::ScannedPage)
    w, h = size(p.image)
    mm(x) = num(x / p.dpi * 25.4)
    io = IOBuffer()
    print(io, """<svg xmlns="http://www.w3.org/2000/svg" class="page" viewBox="0 0 $w $h" width="$(mm(w))mm" height="$(mm(h))mm">\n""")
    print(io, """<rect width="$w" height="$h" fill="#fff"/>\n""")
    figures = p.layout === nothing ? NTuple{4, Float32}[] : p.layout.figures
    for f in figures
        print(io, """<image x="$(num(f[1]))" y="$(num(f[2]))" width="$(num(f[3] - f[1]))" height="$(num(f[4] - f[2]))" """,
              """href="data:image/png;base64,""", figurepng(p.image, f), "\"/>\n")
    end
    for l in renderlines(p), (left, right, ws) in segments(l)
        middle = ((left + right) / 2, (l.style.top + l.style.baseline) / 2)
        hidden = l.style.figure || any(f -> f[1] <= middle[1] <= f[3] && f[2] <= middle[2] <= f[4], figures)
        print(io, """<text x="$(num(left))" y="$(num(l.style.baseline))" font-size="$(num(l.style.size))" """,
              """fill="$(hexcolor(l.style.color))" textLength="$(num(right - left))" lengthAdjust="spacingAndGlyphs\"""",
              hidden ? " fill-opacity=\"0\"" : "", ">", xmlescape(join((x.text for x in ws), ' ')), "</text>\n")
    end
    print(io, "</svg>\n")
    return String(take!(io))
end

function figurepng(img, (x0, y0, x1, y1))
    w, h = size(img)
    crop = img[clamp(floor(Int, x0) + 1, 1, w):clamp(ceil(Int, x1), 1, w), clamp(floor(Int, y0) + 1, 1, h):clamp(ceil(Int, y1), 1, h)]
    io = IOBuffer()
    PNGFiles.save(io, permutedims(crop))
    return base64encode(take!(io))
end

"""
    reconstruction(pages; title = "") -> String

The document as one HTML file holding an SVG per page ([`pagesvg`](@ref)):
vector text and embedded cut-outs, at the pages' printed size.
"""
function reconstruction(pages::AbstractVector{<:ScannedPage}; title::AbstractString = "")
    io = IOBuffer()
    print(io, """<!doctype html>
    <html lang="de"><head><meta charset="utf-8"><title>$(xmlescape(title))</title>
    <style>
    body { margin: 0; background: #777; }
    svg.page { display: block; margin: 16px auto; max-width: calc(100% - 32px); height: auto; box-shadow: 0 2px 8px #0008; }
    svg.page text { font-family: "Liberation Sans", Arimo, Arial, Helvetica, sans-serif; white-space: pre; }
    @media print { body { background: none; } svg.page { margin: 0; box-shadow: none; break-after: page; } }
    </style></head><body>
    """)
    foreach(p -> print(io, pagesvg(p)), pages)
    print(io, "</body></html>\n")
    return String(take!(io))
end
