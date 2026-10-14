# A small PDF writer: one scanned image per page, with the words the OCR read
# laid over it as invisible text, so the PDF can be searched and copied from.
# Writing it here lets every page be read in the background while the next one
# is scanned, and leaves the
# image compression to us: JPEG for colour and grey, 1 bit Flate for black and
# white.
#
# The text is Helvetica in WinAnsiEncoding, which every viewer has and which
# covers German. Each word is stretched with `Tz` to the width of its box.

"""
    PDFPage(img, words = Word[]; dpi = 300, visible = false, quality = 80)

One page: `img[x, y]`, already compressed for the PDF, and the words on it in
the image's pixels. `visible` draws the words instead of hiding them, for pages
that are made of text rather than scanned. Colour and grey images become JPEG
at `quality`, black and white ones 1 bit Flate.
"""
struct PDFPage
    width::Int
    height::Int
    image_dict::String
    image_data::Vector{UInt8}
    words::Vector{Word}
    dpi::Float64
    visible::Bool
end

function PDFPage(img::AbstractMatrix, words::Vector{Word} = Word[]; dpi = 300, visible::Bool = false, quality::Int = 80)
    dict, data = image_object(img; quality)
    return PDFPage(size(img)..., dict, data, words, Float64(dpi), visible)
end

const WINANSI_EXTRA = Dict(
    '€' => 0x80, '‚' => 0x82, 'ƒ' => 0x83, '„' => 0x84, '…' => 0x85, '†' => 0x86, '‡' => 0x87, 'ˆ' => 0x88,
    '‰' => 0x89, 'Š' => 0x8a, '‹' => 0x8b, 'Œ' => 0x8c, 'Ž' => 0x8e, '‘' => 0x91, '’' => 0x92, '“' => 0x93,
    '”' => 0x94, '•' => 0x95, '–' => 0x96, '—' => 0x97, '˜' => 0x98, '™' => 0x99, 'š' => 0x9a, '›' => 0x9b,
    'œ' => 0x9c, 'ž' => 0x9e, 'Ÿ' => 0x9f,
)

"""
    winansi(text) -> Vector{UInt8}

`text` in the PDF's WinAnsiEncoding; characters it lacks become `?`.
"""
function winansi(text::AbstractString)
    return map(collect(text)) do c
        u = UInt32(c)
        (0x20 <= u < 0x7f || 0xa0 <= u <= 0xff) ? UInt8(u) : get(WINANSI_EXTRA, c, UInt8('?'))
    end
end

hexstring(bytes) = "<" * bytes2hex(bytes) * ">"

fmt(x::Real) = string(round(x; digits = 3))

"""
    image_object(img) -> (dict, data)

The image XObject for `img[x, y]`: its dictionary entries and stream data.
"""
function image_object(img::AbstractMatrix{Gray{Bool}}; quality = nothing)
    w, h = size(img)
    rowbytes = cld(w, 8)
    bits = zeros(UInt8, rowbytes * h)
    for y in 1:h, x in 1:w
        # DeviceGray at one bit: 1 is white.
        if Bool(gray(img[x, y]))
            k = (y - 1) * rowbytes + (x - 1) ÷ 8 + 1
            bits[k] |= 0x80 >> ((x - 1) % 8)
        end
    end
    data = transcode(ZlibCompressor, bits)
    return "/Width $w /Height $h /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /FlateDecode", data
end

function image_object(img::AbstractMatrix{<:Gray}; quality::Int = 80)
    w, h = size(img)
    data = jpeg_encode(Gray{N0f8}.(PermutedDimsArray(img,(2,1))); quality)
    return "/Width $w /Height $h /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode", data
end

function image_object(img::AbstractMatrix{<:AbstractRGB}; quality::Int = 80)
    w, h = size(img)
    data = jpeg_encode(RGB{N0f8}.(PermutedDimsArray(img,(2,1))); quality)
    return "/Width $w /Height $h /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", data
end

"""
    text_layer(page) -> String

The content stream operators that put `page.words` where they are on the image.

Hidden words use GlyphLessFont (from Tesseract, Apache 2.0, in `assets`), whose every glyph is exactly half
an em wide and invisible, with the text as UTF-16 code units: a word can then
be stretched to fill its box exactly, so search hits and selections sit on the
words. Visible words use Helvetica.
"""
function text_layer(page::PDFPage)
    isempty(page.words) && return ""
    s = 72 / page.dpi
    height = page.height * s
    io = IOBuffer()
    println(io, "BT")
    println(io, page.visible ? "0 Tr" : "3 Tr")
    for w in page.words
        size_pt = max(w.line_height, w.height) * s
        size_pt <= 0 && continue
        if page.visible
            # The baseline sits about a fifth of the line height above its bottom.
            baseline = height - (w.line_y + w.line_height) * s + 0.2 * size_pt
            println(io, "/F0 ", fmt(size_pt), " Tf 100 Tz 1 0 0 1 ", fmt(w.x * s), " ", fmt(baseline), " Tm ", hexstring(winansi(w.text)), " Tj")
        else
            # GlyphLessFont's glyphs stand on the baseline and are one em tall: the line's box.
            baseline = height - (w.line_y + w.line_height) * s
            units = transcode(UInt16, w.text)
            stretch = 100 * (w.width * s) / (0.5 * size_pt * length(units))
            bytes = reinterpret(UInt8, hton.([units; UInt16(' ')]))
            println(io, "/F1 ", fmt(size_pt), " Tf ", fmt(stretch), " Tz 1 0 0 1 ", fmt(w.x * s), " ", fmt(baseline), " Tm ", hexstring(bytes), " Tj")
        end
    end
    println(io, "ET")
    return String(take!(io))
end

const GLYPHLESS_TOUNICODE = """
/CIDInit /ProcSet findresource begin
12 dict begin
begincmap
/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
/CMapName /Adobe-Identity-UCS def
/CMapType 2 def
1 begincodespacerange
<0000> <FFFF>
endcodespacerange
1 beginbfrange
<0000> <FFFF> <0000>
endbfrange
endcmap
CMapName currentdict /CMap defineresource pop
end
end
"""

"""
    write_pdf(path, pages; title = "") -> path

A PDF with one page per `PDFPage`, each the size of its image at its dpi.
"""
function write_pdf(path::AbstractString, pages::AbstractVector{PDFPage}; title::AbstractString = "")
    io = IOBuffer()
    offsets = Int[]
    object(f, n) = (push!(offsets, position(io)); print(io, n, " 0 obj\n"); f(); print(io, "\nendobj\n"))
    function stream(dict, data)
        print(io, "<< ", dict, " /Length ", length(data), " >>\nstream\n")
        write(io, data)
        print(io, "\nendstream")
    end
    print(io, "%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    npages = length(pages)
    # Objects: 1 catalog, 2 pages, 3 Helvetica, 4 info, 5-10 GlyphLessFont,
    # then per page: page, content, image.
    pageobj(k) = 11 + 3(k - 1)
    object(() -> print(io, "<< /Type /Catalog /Pages 2 0 R >>"), 1)
    object(2) do
        print(io, "<< /Type /Pages /Count $npages /Kids [", join(("$(pageobj(k)) 0 R" for k in 1:npages), " "), "] >>")
    end
    object(() -> print(io, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"), 3)
    object(4) do
        date = Dates.format(Dates.now(), "yyyymmddHHMMSS")
        print(io, "<< /Producer (Paperhawk) /CreationDate (D:$date) /Title ", hexstring([0xfe, 0xff, reinterpret(UInt8, hton.(transcode(UInt16, title)))...]), " >>")
    end
    # GlyphLessFont: every character code is its own CID, and every CID shows glyph 1.
    object(() -> print(io, "<< /Type /Font /Subtype /Type0 /BaseFont /GlyphLessFont /Encoding /Identity-H /DescendantFonts [6 0 R] /ToUnicode 10 0 R >>"), 5)
    object(6) do
        print(io, "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /GlyphLessFont /CIDToGIDMap 7 0 R ",
            "/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor 8 0 R /DW 500 >>")
    end
    object(() -> stream("/Filter /FlateDecode", transcode(ZlibCompressor, repeat(UInt8[0x00, 0x01], 65536))), 7)
    object(8) do
        print(io, "<< /Type /FontDescriptor /FontName /GlyphLessFont /Flags 5 /FontBBox [0 0 500 1000] /ItalicAngle 0 ",
            "/Ascent 1000 /Descent -1 /CapHeight 1000 /StemV 80 /FontFile2 9 0 R >>")
    end
    font = read(joinpath(dirname(@__DIR__), "assets", "GlyphLessFont.ttf"))
    object(() -> stream("/Length1 $(length(font))", font), 9)
    object(() -> stream("", codeunits(GLYPHLESS_TOUNICODE)), 10)
    for (k, page) in enumerate(pages)
        w, h = (page.width, page.height) .* (72 / page.dpi)
        n = pageobj(k)
        object(n) do
            print(io, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ", fmt(w), " ", fmt(h), "] ",
                "/Resources << /XObject << /Im0 $(n + 2) 0 R >> /Font << /F0 3 0 R /F1 5 0 R >> >> /Contents $(n + 1) 0 R >>")
        end
        content = "q " * fmt(w) * " 0 0 " * fmt(h) * " 0 0 cm /Im0 Do Q\n" * text_layer(page)
        object(() -> stream("", codeunits(content)), n + 1)
        object(() -> stream("/Type /XObject /Subtype /Image " * page.image_dict, page.image_data), n + 2)
    end
    xref = position(io)
    print(io, "xref\n0 ", length(offsets) + 1, "\n0000000000 65535 f \n")
    for o in offsets
        print(io, lpad(o, 10, '0'), " 00000 n \n")
    end
    print(io, "trailer\n<< /Size ", length(offsets) + 1, " /Root 1 0 R /Info 4 0 R >>\nstartxref\n", xref, "\n%%EOF\n")
    mkpath(dirname(abspath(path)))
    write(path, take!(io))
    return path
end
