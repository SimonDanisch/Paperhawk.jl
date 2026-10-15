@testset "database, sequential numbering and page sides" begin
    mktempdir() do dir
        page = PDFPage(fill(RGB{N0f8}(1,1,1),124,175),Word[];dpi=15)
        raw(name) = joinpath(dir,"raw",name)
        side(name,sheet,face;blank=false,pdf_page) = Dict{String,Any}("source"=>raw(name),"sheet"=>sheet,"side"=>face,"blank"=>blank,"pdf_page"=>pdf_page)
        a = DocumentArchive(dir)
        try
            @test isfile(joinpath(dir,"archive.sqlite"))
            # A sheet with a blank back, and a two-sided sheet.
            first = archive_document!(a,[page];text="Stadtwerke Süd Stromrechnung März 128,45 Euro",
                sources=[raw("f1"),raw("b1")],sides=[side("f1",1,"front";pdf_page=1),side("b1",1,"back";blank=true,pdf_page=nothing)])
            second = archive_document!(a,[page,page];text="Versicherung Beitragsbescheid\n\f\nVertragsnummer HP4711",
                sources=[raw("f2"),raw("b2")],sides=[side("f2",1,"front";pdf_page=1),side("b2",1,"back";pdf_page=2)])
            @test (first["number"],second["number"]) == (1,2)
            first = document_record(a,1)
            @test first["pages"] == 1
            @test [s["side"] for s in first["sides"]] == ["front","back"]
            @test [s["sheet"] for s in first["sides"]] == [1,1]
            @test first["sides"][2]["blank"] && first["sides"][2]["pdf_page"] === nothing
            @test document_record(a,2)["pages"] == 2
            dbsides = [NamedTuple(r) for r in Paperhawk.DBInterface.execute(a.db,
                "SELECT side,pdf_page FROM sides WHERE document_number=1 ORDER BY capture_order")]
            @test dbsides[1].side == "front" && dbsides[1].pdf_page == 1
            @test dbsides[2].side == "back" && ismissing(dbsides[2].pdf_page)
            @test only(search_documents(a,"stadt marz"))["number"] == 1
            @test only(search_documents(a,"sud 128,45"))["number"] == 1
            @test only(search_documents(a,"1"))["number"] == 1
            @test only(search_documents(a,"000002"))["number"] == 2
            @test only(search_documents(a,"HP4711"))["number"] == 2
            @test isempty(search_documents(a,"\" OR 1=1 --"))
            update_document!(a,1;category="Rechnungen",sender="Stadtwerke Süd",date="2026-03-12",title="Abrechnung Strom")
            @test only(search_documents(a,"abrech";category="Rechnungen",date_from="2026-03-01",date_to="2026-03-31"))["number"] == 1
            @test isempty(search_documents(a,"";date_from="2026-04-01"))
            @test only(search_documents(a,"";sender="Stadtwerke Süd"))["number"] == 1
            @test only(search_documents(a,"";number=2))["number"] == 2
            @test only(search_documents(a;limit=1,offset=1))["number"] == 2
            @test_throws ArgumentError search_documents(a;date_from="not-a-date")
            @test_throws ArgumentError search_documents(a;limit=0)
            # Sides must map every PDF page once, and only blank sides may be left out.
            @test_throws ArgumentError archive_document!(a,[page];text="x",sides=[side("x",1,"front";pdf_page=2)])
            @test_throws ArgumentError archive_document!(a,[page];text="x",
                sides=[side("y",1,"front";pdf_page=1),side("z",1,"back";pdf_page=nothing)])
            # A document can span several physical sheets.
            multi = archive_document!(a,[page,page,page];text="Antrag Seite eins zwei drei",
                sources=[raw("m$k") for k in 1:4],
                sides=[side("m1",1,"front";pdf_page=1),side("m2",1,"back";pdf_page=2),
                       side("m3",2,"front";pdf_page=3),side("m4",2,"back";blank=true,pdf_page=nothing)])
            @test multi["number"] == 3
            @test [s["sheet"] for s in document_record(a,3)["sides"]] == [1,1,2,2]
        finally
            close(a)
        end
        # Reopening continues the sequence; rebuilding the index never renumbers.
        rm(joinpath(dir,"archive.sqlite"))
        a = DocumentArchive(dir)
        try
            @test only(search_documents(a,"abrech"))["number"] == 1
            @test only(search_documents(a,"HP4711"))["number"] == 2
            @test archive_document!(a,[page];text="Neuer Brief",sources=[raw("next")])["number"] == 4
            # Search uses the index and does not reopen every OCR file.
            mv(joinpath(dir,"text"),joinpath(dir,"text-test-away"))
            try
                @test only(search_documents(a,"HP4711"))["number"] == 2
            finally
                mv(joinpath(dir,"text-test-away"),joinpath(dir,"text"))
            end
            # Simulate a crash after a JSON correction but before index update.
            r = document_record(a,1)
            r["title"] = "Nachgetragene Korrektur"
            Paperhawk.atomic_json(Paperhawk.recordpath(a,1),r)
        finally
            close(a)
        end
        a = DocumentArchive(dir)
        try
            @test only(search_documents(a,"nachgetragene"))["number"] == 1
            @test isempty(search_documents(a,"abrech"))
        finally
            close(a)
        end
    end
end
