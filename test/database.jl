@testset "database, sequential numbering and page sides" begin
    mktempdir() do dir
        page = PDFPage(fill(RGB{N0f8}(1,1,1),124,175),Word[];dpi=15)
        side(name,text;blank=false) = Capture(joinpath(dir,"raw",name),false,
            @async(Paperhawk.ProcessedPage(page,blank,0,text)))
        front1,back1 = side("f1","Stadtwerke Süd Stromrechnung März 128,45 Euro"),side("b1","";blank=true)
        front2,back2 = side("f2","Versicherung Beitragsbescheid"),side("b2","Vertragsnummer HP4711")
        captures = [front1,back1,front2,back2]
        a = DocumentArchive(dir)
        try
            @test isfile(joinpath(dir,"archive.sqlite"))
            paths = Paperhawk.write_documents(dir,captures;archive=a,duplex=true,duplex_order=:interleaved,grouping=:sheet)
            @test basename.(paths) == ["000001.pdf","000002.pdf"]
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
            # Front/back order of a reversed stack gives exactly the same IDs.
            @test Paperhawk.write_documents(dir,[front1,front2,back2,back1];archive=a,duplex=true,grouping=:sheet) == paths
            # Missing backs cannot silently shift the document numbering.
            @test_throws ArgumentError Paperhawk.write_documents(dir,captures[1:3];archive=a,duplex=true,grouping=:sheet)
            @test length(search_documents(a)) == 2
            # A multipage document can contain several physical sheets.
            multi = [side("m1","Antrag Seite eins"),side("m2","Antrag Seite zwei"),
                     side("m3","Antrag Seite drei"),side("m4","";blank=true)]
            path = only(Paperhawk.write_documents(dir,multi;archive=a,duplex=true,duplex_order=:interleaved))
            @test basename(path) == "000003.pdf"
            @test document_record(a,3)["pages"] == 3
            @test [s["sheet"] for s in document_record(a,3)["sides"]] == [1,1,2,2]
        finally
            close(a)
        end
        # Reopening continues the sequence; migration/rebuilding never renumbers.
        rm(joinpath(dir,"archive.sqlite"))
        a = DocumentArchive(dir)
        try
            @test only(search_documents(a,"abrech"))["number"] == 1
            @test only(search_documents(a,"HP4711"))["number"] == 2
            p = only(Paperhawk.write_documents(dir,[side("next","Neuer Brief")];archive=a))
            @test basename(p) == "000004.pdf"
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
