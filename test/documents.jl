# From a flat page to a searchable PDF: cleaning, OCR and the text layer.
# Pages are rendered from PDFs with Poppler, so the OCR has real type to read,
# and Poppler is also the PDF reader whose text extraction the text layer has
# to satisfy.

using Poppler_jll
using Paperhawk: Word, PDFPage, write_pdf, paper_size, homography, project

# A processed page as a PDF page and its text.
pdfpage(r; dpi = 300) = PDFPage(r.image, r.words; dpi)
pagetext(r) = Paperhawk.text(r.words)

const LETTER = """
Sehr geehrte Damen und Herren,
hiermit bestätigen wir den Eingang Ihrer Unterlagen vom 12. März 2026.
Die Prüfung Ihres Antrags auf Erstattung der Gebühren ist abgeschlossen.
Der Betrag von 1.284,50 € wird innerhalb von vierzehn Tagen überwiesen.
Bitte beachten Sie, dass Änderungen Ihrer Bankverbindung schriftlich
mitgeteilt werden müssen. Für Rückfragen stehen wir Ihnen gerne zur Verfügung.
Größere Beträge über 5.000 € erfordern eine zusätzliche Bestätigung.
Das Aktenzeichen lautet AZ-2026/04711 und ist bei jeder Anfrage anzugeben.
Mit freundlichen Grüßen
Ihre Verwaltung der Stadtwerke Süd
"""

"""
    render(pdf; dpi = 300) -> Matrix{RGB{N0f8}}

The first page of `pdf` as an image `img[x, y]`, by Poppler.
"""
function render(pdf; dpi = 300)
    base = tempname()
    run(`$(Poppler_jll.pdftoppm()) -r $dpi -png -singlefile $pdf $base`)
    img = map(RGB{N0f8}, permutedims(load(base * ".png")))
    rm(base * ".png")
    return img
end

"""
    pdf_text(pdf) -> Vector{String}

The words a PDF reader extracts from `pdf`, by Poppler.
"""
pdf_text(pdf) = split(read(`$(Poppler_jll.pdftotext()) $pdf -`, String))

"""
    letter_page() -> Matrix{RGB{N0f8}}

An A4 letter in 11 pt Helvetica at 300 dpi.
"""
function letter_page(; dpi = 300)
    w, h = paper_size(:a4; dpi)
    size = round(Int, 11 * dpi / 72)
    lines = filter(!isempty, split(LETTER, '\n'))
    words = [Word(line, 250, 300 + 2size * (i - 1), 0, size, 300 + 2size * (i - 1), size, 100) for (i, line) in enumerate(lines)]
    pdf = write_pdf(tempname() * ".pdf", [PDFPage(fill(Gray(true), w, h), words; dpi, visible = true)])
    img = render(pdf; dpi)
    rm(pdf)
    return img
end

@testset "documents" begin
    letter = letter_page()
    truth = split(LETTER)

    # Pages are warped, cleaned and read on the GPU only.
    ocr = PaddleOCR()

    @testset "a failing GPU request reports its error and releases priority" begin
        failure=try
            Paperhawk.ongpu(_->error("priority cleanup test"),ocr)
            nothing
        catch err
            err
        end
        @test failure isa CapturedException
        @test failure.ex isa ErrorException && failure.ex.msg=="priority cleanup test"
        @test ocr.demand[]==0
    end

    @testset "a letter, read and written to a searchable PDF" begin
        page = process_page(ocr, letter)
        found = split(pagetext(page))
        accuracy = count(in(Set(found)), truth) / length(truth)
        @info "PP-OCRv6 word accuracy" accuracy
        @test accuracy >= 0.98
        @test page.rotation == 0
        @test !page.blank
        pdf = write_pdf(tempname() * ".pdf", [pdfpage(page)])
        @test pdf_text(pdf) == found
        # Word boxes lie inside their line, left to right.
        @test all(w -> w.width > 0 && w.x >= 0, page.words)
        # Pages are read in tasks on other threads, and only the thread that
        # made the GPU's device may submit to it: the engine's worker carries
        # the request over. Two at once, as a fast stack does.
        tasks = [Threads.@spawn process_page(ocr, letter) for _ in 1:2]
        @test all(t -> pagetext(fetch(t)) == pagetext(page), tasks)
        # The words of the page as it is, without the cleanup.
        @test count(in(Set(w.text for w in read_words(ocr, letter))), truth) / length(truth) >= 0.98
    end

    @testset "upside down and sideways pages are turned upright" begin
        for degrees in (90, 180, 270)
            # PP-LCNet's page classifier on its own, and the whole page.
            @test mod(Paperhawk.orientation(ocr, turn(letter, degrees)) + degrees, 360) == 0
            page = process_page(ocr, turn(letter, degrees))
            @test mod(page.rotation + degrees, 360) == 0
            @test size(page.image) == size(letter)
            @test count(in(Set(split(pagetext(page)))), truth) / length(truth) >= 0.95
        end
    end

    @testset "blank pages" begin
        @test process_page(ocr, fill(RGB{N0f8}(0.93, 0.92, 0.9), size(letter))).blank
        @test !process_page(ocr, letter).blank
    end

    @testset "output modes" begin
        image(mode) = process_page(ocr, letter; mode).image
        @test eltype(image(:color)) == RGB{N0f8}
        grey = image(:gray)
        @test eltype(grey) == Gray{N0f8} && size(grey) == size(letter)
        bw = image(:bw)
        @test eltype(bw) == Gray{Bool} && size(bw) == size(letter)
        # Ink is black, paper white: about as much ink as in grey.
        @test isapprox(count(c -> !gray(c), bw) / length(bw), count(c -> gray(c) < 0.5, grey) / length(grey); atol = 0.01)
        @test_throws ArgumentError image(:sepia)
        pdf = write_pdf(tempname() * ".pdf", [PDFPage(bw)])
        @test size(render(pdf; dpi = 300)) == size(letter)
    end

    @testset "a sheet in a camera frame, warped flat on the GPU" begin
        # The letter on a dark desk, a little rotated, as the camera sees it.
        corners = (Vec2f(700.3, 300.7), Vec2f(3180.2, 385.1), Vec2f(3090.6, 3381.4), Vec2f(580.9, 3300.2))
        sheet = (Vec2f(0.5, 0.5), Vec2f(size(letter, 1) + 0.5, 0.5), Vec2f(size(letter, 1) + 0.5, size(letter, 2) + 0.5), Vec2f(0.5, size(letter, 2) + 0.5))
        H = homography(corners, sheet)
        frame = [begin
                     p = project(H, Vec2f(x, y))
                     1 <= p[1] <= size(letter, 1) && 1 <= p[2] <= size(letter, 2) ? letter[round(Int, p[1]), round(Int, p[2])] : RGB{N0f8}(0.12, 0.1, 0.09)
                 end for x in 1:3900, y in 1:3600]
        found = findsheet(frame)
        @test found !== nothing
        page = process_page(ocr, frame; corners = found.corners)
        @test count(in(Set(split(pagetext(page)))), truth) / length(truth) >= 0.95
        @test size(page.image) == paper_size(:a4)
    end

    @testset "UVDoc before OCR and searchable PDF" begin
        corrected = fetch(Threads.@spawn process_page(ocr, letter; dewarp = true))
        @test !corrected.blank
        @test count(in(Set(split(pagetext(corrected)))), truth) / length(truth) >= 0.95
        pdf = write_pdf(tempname() * ".pdf", [pdfpage(corrected)])
        @test pdf_text(pdf) == split(pagetext(corrected))
        @test all(w -> w.width > 0 && w.x >= 0, corrected.words)
        @test process_page(ocr, fill(RGB{N0f8}(0.93, 0.92, 0.9), size(letter)); dewarp = true).blank
        rm(pdf)
    end
    close(ocr)
end
