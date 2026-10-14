# From a flat page to a searchable PDF: cleaning, OCR, the text layer, QR
# codes, and how captures become documents. Pages are rendered from PDFs
# with Poppler, so the OCR has real type to read, and Poppler is also the PDF
# reader whose text extraction the text layer has to satisfy.

using Poppler_jll
using Paperhawk: Word, PDFPage, write_pdf, paper_size, qr_image, qr_codes, SEPARATOR_TEXT,
    Capture, documents, homography, project

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

    @testset "QR codes made here, read by zbar" begin
        for text in (SEPARATOR_TEXT, "a", "https://example.com/x?y=1", "x"^42)
            img = map(c -> RGB{N0f8}(gray(c), gray(c), gray(c)), qr_image(text; module_size = 6))
            @test qr_codes(img; width = 10_000) == [text]
        end
        @test_throws ArgumentError qr_image("x"^43)
    end

    @testset "separator sheet" begin
        path = separator_sheet(tempname() * ".pdf")
        sheet = render(path; dpi = 150)
        @test isseparator(sheet)
        @test !isseparator(letter)
        @test "Trennblatt" in pdf_text(path)
    end

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
        @test Paperhawk.OCR_PENDING[]==0
    end

    @testset "a letter, read and written to a searchable PDF" begin
        page = process_page(letter; ocr)
        found = split(page.text)
        accuracy = count(in(Set(found)), truth) / length(truth)
        @info "PP-OCRv6 word accuracy" accuracy
        @test accuracy >= 0.98
        @test page.rotation == 0
        @test !page.blank
        pdf = write_pdf(tempname() * ".pdf", [page.page])
        @test pdf_text(pdf) == found
        # Word boxes lie inside their line, left to right.
        @test all(w -> w.width > 0 && w.x >= 0, page.page.words)
        # The scanner reads pages in tasks on other threads, and only the
        # thread that made the GPU's submit channel may use it: the worker
        # has to carry the request over. Two at once, as a fast stack does.
        tasks = [Threads.@spawn process_page(letter; ocr) for _ in 1:2]
        @test all(t -> fetch(t).text == page.text, tasks)
    end

    @testset "upside down and sideways pages are turned upright" begin
        for degrees in (90, 180, 270)
            # PP-LCNet's page classifier on its own, and the whole page.
            @test mod(orientation(ocr, turn(letter, degrees)) + degrees, 360) == 0
            page = process_page(turn(letter, degrees); ocr)
            @test mod(page.rotation + degrees, 360) == 0
            @test count(in(Set(split(page.text))), truth) / length(truth) >= 0.95
        end
    end

    @testset "blank pages" begin
        @test process_page(fill(RGB{N0f8}(0.93, 0.92, 0.9), size(letter)); ocr).blank
        @test !process_page(letter; ocr).blank
    end

    @testset "output modes" begin
        image(mode) = last(Paperhawk.process_page_image(letter; ocr, mode))
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
        page = process_page(frame; ocr, corners = found.corners)
        @test count(in(Set(split(page.text))), truth) / length(truth) >= 0.95
        @test (page.page.width, page.page.height) == paper_size(:a4)
    end

    if Paperhawk.ongpu(_->Paperhawk.UVDocRunner.ready(),ocr)
        @testset "UVDoc before OCR and searchable PDF" begin
            dewarper = uvdoc(ocr)
            try
                corrected = fetch(Threads.@spawn process_page(letter; ocr, dewarper))
                @test !corrected.blank
                @test count(in(Set(split(corrected.text))), truth) / length(truth) >= 0.95
                pdf = write_pdf(tempname() * ".pdf", [corrected.page])
                @test pdf_text(pdf) == split(corrected.text)
                @test all(w -> w.width > 0 && w.x >= 0, corrected.page.words)
                @test process_page(fill(RGB{N0f8}(0.93, 0.92, 0.9), size(letter)); ocr, dewarper).blank
                rm(pdf)
            finally
                close(dewarper)
            end
        end
    end
    close(ocr)

    @testset "captures become documents" begin
        side(name, separator = false) = Capture(name, separator, nothing)
        names(docs) = [[c.raw for c in d] for d in docs]
        # One-sided: separators split, and are left out.
        simplex = [side("a1"), side("a2"), side("sep", true), side("b1"), side("sep", true)]
        @test names(documents(simplex)) == [["a1", "a2"], ["b1"]]
        # Duplex: fronts a, b, separator, c; then the backs, last sheet first.
        duplex = [side("a"), side("b"), side("sep", true), side("c"), side("c'"), side("sep'"), side("b'"), side("a'")]
        @test names(documents(duplex; duplex = true)) == [["a", "a'", "b", "b'"], ["c", "c'"]]
        # An odd number of sides cannot be duplex: kept as scanned.
        odd = @test_logs (:warn,) documents(duplex[1:7]; duplex = true)
        @test names(odd) == [["a", "b"], ["c", "c'", "sep'", "b'"]]
    end
end
