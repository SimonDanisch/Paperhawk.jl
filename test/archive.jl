using Paperhawk: parse_classification, numbered_separator, document_groups
struct UnusedArchiveCamera <: Camera end
# Never reached: start checks its arguments before reading or processing anything.
struct UnusedArchiveOCR <: Paperhawk.OCREngine end

@testset "numbered document archive" begin
    metadata = Dict("category"=>"Rechnungen","sender"=>"Stadtwerke Süd","date"=>"2026-03-12",
        "title"=>"Stromrechnung März","summary"=>"Stromrechnung über 128,45 Euro.","needs_review"=>false)
    raw = Paperhawk.JSON3.write(metadata)
    @test parse_classification(raw,Paperhawk.DEFAULT_CATEGORIES)["sender"] == "Stadtwerke Süd"
    @test_throws ArgumentError parse_classification(replace(raw,"2026-03-12"=>"2026-02-30"),Paperhawk.DEFAULT_CATEGORIES)
    @test_throws ArgumentError parse_classification(replace(raw,"Rechnungen"=>"../../elsewhere"),Paperhawk.DEFAULT_CATEGORIES)
    @test_throws ArgumentError parse_classification(Paperhawk.JSON3.write(merge(metadata,Dict("number"=>42))),Paperhawk.DEFAULT_CATEGORIES)
    @test numbered_separator(["ASCANNER:DOC:000123"]) == 123
    @test numbered_separator(["not a number"]) === nothing
    @test_throws ArgumentError numbered_separator(["ASCANNER:DOC:000123","ASCANNER:DOC:000124"])

    page = PDFPage(fill(RGB{N0f8}(1,1,1),124,175),Word[];dpi=15)
    mktempdir() do dir
        mkpath(joinpath(dir,"raw"))
        write(joinpath(dir,"raw","page_001.png"),"existing capture")
        @test_throws ArgumentError start(UnusedArchiveCamera();dir,ocr=UnusedArchiveOCR())
        @test read(joinpath(dir,"raw","page_001.png"),String) == "existing capture"
    end
    mktempdir() do dir
        calls = Ref(0)
        fake(text,categories) = (calls[]+=1; (metadata=metadata,raw=raw,model="test classifier"))
        a = DocumentArchive(dir;classifier=fake)
        try
            @test_throws Exception DocumentArchive(dir) # a second writer cannot race ID assignment
            @test reserve_numbers!(a,2) == [1,2]
            source = [joinpath(dir,"raw","page_001.png")]
            r = archive_document!(a,[page];text="Stadtwerke Süd\nRechnung 12.03.2026\n128,45 Euro",sources=source,number=2)
            @test r["number"] == 2
            @test isfile(joinpath(dir,r["pdf"]))
            @test isfile(joinpath(dir,r["text"]))
            wait_archive(a)
            @test document_record(a,2)["status"] == "classified"
            @test only(search_documents(a,"stadtwerke stromrechnung"))["number"] == 2
            @test only(search_documents(a,"128,45"))["number"] == 2
            @test isempty(search_documents(a,"";category="Arbeit"))
            duplicate = archive_document!(a,[page];text="same capture reprocessed",sources=source)
            @test duplicate["number"] == 2
            @test calls[] == 1
            @test_throws ArgumentError archive_document!(a,[page];text="different",number=2)
            @test_throws ArgumentError archive_document!(a,[page];text="unreserved",number=99)
            updated = update_document!(a,2;title="Strom März 2026")
            @test updated["status"] == "reviewed"
            @test updated["pdf"] == r["pdf"]
            @test_throws ArgumentError update_document!(a,2;pdf="bad.pdf")

            # Interrupted writes retain their ID and can be retried by the
            # same source only; a different capture cannot take the number.
            recover_source = [joinpath(dir,"raw","interrupted.png")]
            key = bytes2hex(Paperhawk.SHA.sha256(Paperhawk.JSON3.write(abspath.(recover_source))))
            Paperhawk.atomic_json(joinpath(dir,"numbers","000001","claim.json"),Dict("source_key"=>key))
            Paperhawk.atomic_json(joinpath(dir,"sources",key*".json"),Dict("number"=>1))
            @test_throws ArgumentError archive_document!(a,[page];text="other",sources=["other.png"],number=1)
            recovered = archive_document!(a,[page];text="Recovered Rechnung",sources=recover_source)
            @test recovered["number"] == 1
            wait_archive(a)

            numbers = number_sheets(a,joinpath(dir,"covers.pdf");count=2,dpi=100)
            @test numbers == [3,4]
            cover = render(joinpath(dir,"covers.pdf");dpi=150)
            @test numbered_separator(qr_codes(cover)) == 3
            @test isseparator(cover)
            @test "000003" in pdf_text(joinpath(dir,"covers.pdf"))
            # Cover goes BEFORE its document and is omitted from the PDF.
            processed = Paperhawk.ProcessedPage(page,false,0,"Test Rechnung")
            firstpage = Capture(joinpath(dir,"raw","p1.png"),false,@async(processed))
            secondpage = Capture(joinpath(dir,"raw","p2.png"),false,@async(processed))
            covers = [Capture("cover3",true,nothing,3),firstpage,Capture("cover4",true,nothing,4),secondpage]
            @test [g.number for g in document_groups(covers)] == [3,4]
            paths = Paperhawk.write_documents(dir,covers;archive=a)
            @test basename.(paths) == ["000003.pdf","000004.pdf"]
            @test Paperhawk.write_documents(dir,covers;archive=a) == paths
            wait_archive(a)
            @test document_record(a,3)["pages"] == 1
            # Fronts cover, front; then back, reverse of cover: one two-sided document.
            duplex = [covers[1],firstpage,secondpage,Capture("coverback",false,@async(processed))]
            group = only(document_groups(duplex;duplex=true))
            @test group.number == 3 && length(group.captures) == 2
        finally
            close(a)
        end
        reopened = DocumentArchive(dir)
        try
            @test reserve_numbers!(reopened) == [5]
            @test document_record(reopened,2)["title"] == "Strom März 2026"
        finally
            close(reopened)
        end
    end

    @testset "queue failures and restart recovery" begin
        mktempdir() do dir
            a = DocumentArchive(dir)
            r = archive_document!(a,[page];text="Rechnung",sources=[joinpath(dir,"one.png")])
            @test r["status"] == "pending"
            close(a)
            fail(text,categories) = error("model unavailable")
            a = DocumentArchive(dir;classifier=fail)
            try
                wait_archive(a)
                r = document_record(a,1)
                @test r["status"] == "needs_review"
                @test occursin("model unavailable",r["error"])
                @test isfile(joinpath(dir,r["pdf"]))
                a.classifier = (text,categories) -> (metadata=metadata,raw=raw,model="recovered")
                retry_classification!(a,1)
                wait_archive(a)
                @test document_record(a,1)["status"] == "classified"
            finally
                close(a)
            end
        end
    end

    @testset "slow model does not delay saving; human edits win" begin
        mktempdir() do dir
            entered,release = Channel{Nothing}(1),Channel{Nothing}(1)
            slow(text,categories) = (put!(entered,nothing);take!(release);(metadata=metadata,raw=raw,model="slow"))
            a = DocumentArchive(dir;classifier=slow)
            try
                r = archive_document!(a,[page];text="Rechnung")
                take!(entered)
                @test isfile(joinpath(dir,r["pdf"]))
                @test only(search_documents(a,"Rechnung"))["number"]==1
                @test document_record(a,1)["status"]=="pending"
                update_document!(a,1;category="Rechnungen",title="Manuell korrigiert")
                put!(release,nothing)
                wait_archive(a)
                @test document_record(a,1)["title"] == "Manuell korrigiert"
                @test document_record(a,1)["status"] == "reviewed"
            finally
                isready(release) || put!(release,nothing)
                close(a)
            end
        end
    end
end
