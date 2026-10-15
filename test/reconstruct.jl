using Paperhawk: LineStyle, PageLayout, ScannedPage, markdown, reconstruction, pagesvg, segments, renderlines

# A line set at `baseline` in `size`, from `left` to `right`, its OCR box around
# it, and its words at their x positions.
function setline(words, baseline, size; left = 100.0f0, right = 900.0f0, figure = false)
    box = (left - 10, baseline - size, right + 10, baseline + 0.3f0 * size)
    style = LineStyle(box, left, right, baseline - 0.75f0 * size, baseline, baseline + 0.2f0 * size, 0.5f0 * size, size,
                      (0x10, 0x20, 0x30), 3.0f0, figure)
    top, height = round(Int, box[2]), round(Int, box[4] - box[2])
    return style, [Word(t, x, top, w, height, top, height, 99.0f0) for (t, x, w) in words]
end

@testset "Markdown and vector reconstruction" begin
    lines = [setline([("Rechnung", 100, 400)], 100, 80),
             setline([("Sehr", 100, 80), ("geehrte", 200, 150)], 250, 40),
             setline([("Damen", 100, 120), ("und", 240, 60), ("Herren,", 320, 140)], 300, 40),
             setline([("Betrag", 100, 120), ("*fällig*", 240, 140)], 450, 40),
             setline([("Datum:", 100, 120), ("12.03.2026", 700, 200)], 500, 40),
             setline([("wwwn", 120, 300)], 640, 60; left = 110.0f0, right = 420.0f0, figure = true)]
    figure = (100.0f0, 560.0f0, 440.0f0, 680.0f0)
    layout = PageLayout((1000, 800), first.(lines), [figure])
    page = ScannedPage(fill(RGB{N0f8}(1, 1, 1), 1000, 800), reduce(vcat, last.(lines)), layout, 300)

    md = markdown([page]; title = "000007 — Rechnung")
    @test startswith(md, "# 000007 — Rechnung\n\n# Rechnung\n\n")
    # One paragraph keeps its lines; a larger gap starts the next.
    @test occursin("Sehr geehrte\nDamen und Herren,\n\nBetrag", md)
    @test occursin("Betrag \\*fällig\\*", md)
    # A signature read as letters is not text.
    @test !occursin("wwwn", md)

    svg = pagesvg(page)
    @test count("<text", svg) == 7   # the dated line is two runs
    @test count("<image", svg) == 1
    @test occursin(">wwwn</text>", svg) && occursin("fill-opacity=\"0\">wwwn", svg)
    @test occursin("fill=\"#102030\"", svg)
    dated = segments(renderlines(page)[5])
    @test length(dated) == 2 && dated[1][1] == 100 && dated[2][2] == 900
    @test occursin("<svg", reconstruction([page, page]; title = "x")) && count("<svg", reconstruction([page, page])) == 2

    # The layout survives the draft's JSON.
    back = PageLayout(Paperhawk.JSON3.read(Paperhawk.JSON3.write(layout), Dict{String, Any}))
    @test back.size == layout.size && back.lines == layout.lines && back.figures == layout.figures

    # A draft from before layouts: the words alone, styled from their boxes.
    old = ScannedPage(page.image, page.words, nothing, 300)
    @test occursin("Damen und Herren,", markdown([old]))
    @test count("<text", pagesvg(old)) >= 6
end

@testset "page layout measured on the GPU" begin
    letter = load(joinpath(pkgdir(Paperhawk), "dev", "JuliaVision", "PPOCRRunner", "test", "letter.png"))
    page = fill(RGB{N0f8}(1, 1, 1), 2000, 1500)   # [x, y]
    lh, lw = size(letter)
    page[101:100 + lw, 301:300 + lh] .= RGB{N0f8}.(permutedims(letter))
    for x in 1600:1900, y in 40:240    # a logo
        ((x - 1750) / 150)^2 + ((y - 140) / 100)^2 <= 1 && (page[x, y] = RGB{N0f8}(0.1, 0.25, 0.7))
    end
    for x in 1500:1900, y in 1050:1450  # a stamp: two rings
        r = sqrt((x - 1700)^2 + (y - 1250)^2)
        (170 <= r <= 190 || 120 <= r <= 128) && (page[x, y] = RGB{N0f8}(0.75, 0.1, 0.1))
    end
    ocr = PaddleOCR()
    try
        result = process_page(ocr, page)
        layout = result.layout
        text = filter(l -> !l.figure, layout.lines)
        @test length(text) >= 8
        sizes = [l.size for l in text[1:8]]
        @test maximum(sizes) / minimum(sizes) < 1.25
        # The ink inside the OCR's box, the baseline below the top.
        @test all(l -> l.box[1] - 1 <= l.left < l.right <= l.box[3] + 1 && l.box[2] - 1 <= l.top < l.baseline <= l.box[4] + 1, text)
        @test all(l -> all(<(0x60), l.color), text)
        near(f, g) = all(abs.(f .- g) .<= 12)
        @test any(f -> near(f, (1599, 39, 1900, 240)), layout.figures)
        @test any(f -> near(f, (1509, 1059, 1890, 1440)), layout.figures)
        # The stamp's inner ring is part of the stamp.
        @test !any(f -> near(f, (1571, 1121, 1828, 1378)), layout.figures)
        scan = ScannedPage(result.image, result.words, layout, 300)
        @test occursin("Sehr geehrte Damen und Herren,", markdown([scan]))
        @test count("<image", pagesvg(scan)) == length(layout.figures)
    finally
        close(ocr)
    end
end
