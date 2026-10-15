using Paperhawk: parse_classification

@testset "numbered document archive" begin
    metadata = Dict("category"=>"Rechnungen","sender"=>"Stadtwerke Süd","date"=>"2026-03-12",
        "title"=>"Stromrechnung März","summary"=>"Stromrechnung über 128,45 Euro.","needs_review"=>false)
    raw = Paperhawk.JSON3.write(metadata)
    @test parse_classification(raw,Paperhawk.DEFAULT_CATEGORIES)["sender"] == "Stadtwerke Süd"
    @test_throws ArgumentError parse_classification(replace(raw,"2026-03-12"=>"2026-02-30"),Paperhawk.DEFAULT_CATEGORIES)
    @test_throws ArgumentError parse_classification(replace(raw,"Rechnungen"=>"../../elsewhere"),Paperhawk.DEFAULT_CATEGORIES)
    @test_throws ArgumentError parse_classification(Paperhawk.JSON3.write(merge(metadata,Dict("number"=>42))),Paperhawk.DEFAULT_CATEGORIES)

    page = PDFPage(fill(RGB{N0f8}(1,1,1),124,175),Word[];dpi=15)
    mktempdir() do dir
        calls = Ref(0)
        fake(text,categories) = (calls[]+=1; (metadata=metadata,raw=raw,model="test classifier"))
        a = DocumentArchive(dir;classifier=fake)
        try
            @test_throws Exception DocumentArchive(dir) # a second writer cannot race ID assignment
            source = [joinpath(dir,"raw","page_001.png")]
            r = archive_document!(a,[page];text="Stadtwerke Süd\nRechnung 12.03.2026\n128,45 Euro",sources=source)
            @test r["number"] == 1
            @test isfile(joinpath(dir,r["pdf"]))
            @test isfile(joinpath(dir,r["text"]))
            wait_archive(a)
            @test document_record(a,1)["status"] == "classified"
            @test only(search_documents(a,"stadtwerke stromrechnung"))["number"] == 1
            @test only(search_documents(a,"128,45"))["number"] == 1
            @test isempty(search_documents(a,"";category="Arbeit"))
            # The same captures committed again are the same document.
            duplicate = archive_document!(a,[page];text="same capture reprocessed",sources=source)
            @test duplicate["number"] == 1
            @test calls[] == 1
            updated = update_document!(a,1;title="Strom März 2026")
            @test updated["status"] == "reviewed"
            @test updated["pdf"] == r["pdf"]
            @test_throws ArgumentError update_document!(a,1;pdf="bad.pdf")

            # An interrupted write keeps its number and is finished by the same
            # captures; a different capture cannot take that number over.
            recover_source = [joinpath(dir,"raw","interrupted.png")]
            key = bytes2hex(Paperhawk.SHA.sha256(Paperhawk.JSON3.write(abspath.(recover_source))))
            mkpath(joinpath(dir,"numbers","000002"))
            Paperhawk.atomic_json(joinpath(dir,"numbers","000002","claim.json"),Dict("source_key"=>key))
            Paperhawk.atomic_json(joinpath(dir,"sources",key*".json"),Dict("number"=>2))
            other = archive_document!(a,[page];text="other",sources=[joinpath(dir,"raw","other.png")])
            @test other["number"] == 3
            recovered = archive_document!(a,[page];text="Recovered Rechnung",sources=recover_source)
            @test recovered["number"] == 2
            wait_archive(a)
        finally
            close(a)
        end
        reopened = DocumentArchive(dir)
        try
            # Reopening continues the sequence.
            @test archive_document!(reopened,[page];text="Neuer Brief")["number"] == 4
            @test document_record(reopened,1)["title"] == "Strom März 2026"
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
