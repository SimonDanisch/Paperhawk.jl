using Paperhawk: ReviewSession, review_add!, review_edit!, review_delete!, review_move!, review_undo!, review_wait,
    review_groups, review_issues, review_commit!

@testset "worker memory failure preserves originals and remains reviewable" begin
    mktempdir() do dir
        processor=(args...)->fetch(Threads.@spawn throw(OutOfMemoryError()))
        draft=ReviewSession(dir;duplex=false,processor)
        image=fill(RGB{N0f8}(0.2,0.3,0.4),40,60)
        try
            review_add!(draft,image);review_wait(draft)
            entry=only(draft.entries)
            @test entry.status==:error
            @test occursin("Speichergrenze erreicht",entry.error)
            @test permutedims(load(entry.source))==image
            @test !isempty(review_issues(draft))
        finally
            close(draft)
        end
    end
end

@testset "editable scan draft" begin
    img=fill(RGB{N0f8}(0.6,0.6,0.6),100,140)
    blank=fill(RGB{N0f8}(1,1,1),100,140)
    function fake_processor(src,corners,rotation,out)
        image=permutedims(load(src))
        angle=rotation===nothing ? 0 : rotation
        image=turn(image,angle)
        save(out,permutedims(image))
        empty=gray(Gray(image[1,1]))>0.95
        (words=empty ? Word[] : [Word("Rechnnng",10,15,60,12,15,12,70f0)],blank=empty,rotation=angle)
    end
    mktempdir() do dir
        a=DocumentArchive(joinpath(dir,"archive"))
        s=ReviewSession(joinpath(dir,"draft");processor=fake_processor)
        try
            first=review_add!(s,img)
            review_wait(s)
            @test occursin("Rückseite fehlt",join(review_issues(s)))
            @test isempty(search_documents(a))
            second=review_add!(s,blank)
            review_wait(s)
            @test isempty(review_issues(s))
            @test !s.entries[2].included && s.entries[2].side==:back
            review_edit!(s,second;included=true)
            @test s.entries[2].included
            @test review_undo!(s)
            @test !s.entries[2].included
            review_edit!(s,first;rotation=90)
            review_wait(s)
            @test size(permutedims(load(s.entries[1].output)))==(140,100)
            @test s.entries[1].detected_rotation==90
            Paperhawk.review_word!(s,first,1,"Rechnung")
            @test s.entries[1].words[1].text=="Rechnung"
            review_undo!(s)
            @test s.entries[1].words[1].text=="Rechnnng"
            review_delete!(s,second)
            @test length(s.entries)==1
            @test !isempty(review_issues(s))
            review_undo!(s);review_wait(s)
            @test length(s.entries)==2
            review_move!(s,first,1)
            @test !isempty(review_issues(s))
            review_undo!(s)
            @test s.entries[1].id==first
            # Replace keeps the page's position, side and document assignment.
            oldsource=s.entries[1].source
            @test review_add!(s,img;replace_id=first)==first
            review_wait(s)
            @test length(s.entries)==2 && isfile(oldsource)
            @test s.entries[1].source!=oldsource && s.entries[1].side==:front
            Paperhawk.review_word!(s,first,1,"Rechnung")
            close(s)
            s=ReviewSession(joinpath(dir,"draft");processor=fake_processor)
            @test s.entries[1].words[1].text=="Rechnung"
            @test isempty(review_issues(s))
            paths=review_commit!(s,a)
            @test basename.(paths)==["000001.pdf"]
            @test only(search_documents(a,"rechnung"))["number"]==1
            @test document_record(a,1)["pages"]==1
            @test document_record(a,1)["sides"][2]["pdf_page"]===nothing
            @test review_commit!(s,a)==paths
            other=DocumentArchive(joinpath(dir,"other-archive"))
            try
                @test_throws ArgumentError review_commit!(s,other)
                @test isempty(search_documents(other))
            finally
                close(other)
            end
            @test_throws ArgumentError review_delete!(s,first)
            close(s)
            s=ReviewSession(joinpath(dir,"draft");processor=fake_processor)
            @test review_commit!(s,a)==paths
        finally
            close(s);close(a)
        end
    end
    @testset "stale OCR cannot undo a correction" begin
        mktempdir() do dir
            entered,release=Channel{Nothing}(1),Channel{Nothing}(1)
            calls=Threads.Atomic{Int}(0)
            process(src,corners,rot,out)=begin
                if Threads.atomic_add!(calls,1)==0
                    put!(entered,nothing);take!(release)
                end
                fake_processor(src,corners,rot,out)
            end
            s=ReviewSession(dir;processor=process,duplex=false,workers=1)
            try
                id=review_add!(s,img);take!(entered)
                second=review_add!(s,img)
                # Original and preview must be available while the first
                # page's OCR is deliberately blocked.
                @test timedwait(()->isfile(s.entries[2].source),5)==:ok
                @test s.entries[2].status==:queued
                review_edit!(s,id;rotation=90)
                @test review_undo!(s)
                put!(release,nothing);review_wait(s)
                @test s.entries[1].detected_rotation==0
                @test s.entries[1].status==:ready
                @test isfile(s.entries[1].source)
            finally
                isready(release) || put!(release,nothing)
                close(s)
            end
        end
    end
    @testset "document boundaries and processing failure" begin
        mktempdir() do dir
            s=ReviewSession(dir;duplex=false,processor=fake_processor)
            try
                x=review_add!(s,img);y=review_add!(s,img);review_wait(s)
                @test length(review_groups(s))==2
                review_edit!(s,y;starts=false)
                @test length(review_groups(s))==1
                review_edit!(s,y;starts=true)
                @test length(review_groups(s))==2
                s.processor=(args...)->error("OCR test failure")
                review_edit!(s,x;retry=true);review_wait(s)
                @test s.entries[1].status==:error
                @test occursin("OCR test failure",join(review_issues(s)))
                s.processor=fake_processor
                review_edit!(s,x;retry=true);review_wait(s)
                @test isempty(review_issues(s))
                @test_throws ArgumentError Paperhawk.review_validate_corners((Vec2f(1,1),Vec2f(80,120),Vec2f(80,1),Vec2f(1,120)),(100,140))
                @test Paperhawk.review_validate_corners((Vec2f(1,1),Vec2f(80,1),Vec2f(80,120),Vec2f(1,120)),(100,140)) !== nothing
            finally
                close(s)
            end
        end
    end
    @testset "bounded parallel pages preserve order" begin
        mktempdir() do dir
            entered,release=Channel{Nothing}(1),Channel{Nothing}(1)
            calls=Threads.Atomic{Int}(0)
            process(src,corners,rot,out)=begin
                if Threads.atomic_add!(calls,1)==0
                    put!(entered,nothing);take!(release)
                end
                fake_processor(src,corners,rot,out)
            end
            s=ReviewSession(dir;duplex=false,processor=process,workers=2)
            try
                first=review_add!(s,img);take!(entered)
                second=review_add!(s,img)
                # Page 2 finishes while page 1 remains deliberately blocked.
                @test timedwait(()->s.entries[2].status==:ready,5)==:ok
                third=review_add!(s,img)
                @test timedwait(()->s.entries[3].status==:ready,5)==:ok
                @test s.entries[1].status==:processing
                barrier=@async review_wait(s)
                yield()
                @test !istaskdone(barrier)
                put!(release,nothing);wait(barrier)
                @test [e.id for e in s.entries]==[first,second,third]
                @test all(e->e.status==:ready,s.entries)
            finally
                isready(release) || put!(release,nothing)
                close(s)
            end
        end
    end
end
