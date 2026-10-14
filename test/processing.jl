using Distributed

@testset "processing is isolated from UI events" begin
    pid=Paperhawk.processing_pid()
    @test pid!=Distributed.myid()
    ticks=UInt64[]
    timer=Timer(_->push!(ticks,time_ns()),0;interval=0.01)
    try
        sleep(0.1) # compile the timer callback before the timed worker operation
        started,finished=remotecall_fetch(pid) do
            started=time_ns()
            while time_ns()-started<800_000_000
            end
            GC.gc(true)
            (started,time_ns())
        end
        @test count(t->started<=t<=finished,ticks)>=10
        @test finished-started>=800_000_000
    finally
        close(timer)
    end
    # Scan-pause transitions reach the same process that owns Bonsai and OCR.
    baseline=remotecall_fetch(()->Paperhawk.SCAN_ACTIVE[],pid)
    Paperhawk.process_scan_activity(1)
    @test timedwait(()->remotecall_fetch(()->Paperhawk.SCAN_ACTIVE[],pid)==baseline+1,5)==:ok
    Paperhawk.process_scan_activity(-1)
    @test timedwait(()->remotecall_fetch(()->Paperhawk.SCAN_ACTIVE[],pid)==baseline,5)==:ok
end

@testset "worker failure preserves the original and releases priority" begin
    mktempdir() do dir
        baseline=Paperhawk.OCR_PENDING[]
        image=fill(Paperhawk.RGB{Paperhawk.N0f8}(0.5,0.3,0.1),100,140)
        draft=Paperhawk.ReviewSession(dir;duplex=false,ocr=Paperhawk.ProcessOCR(-1,-1))
        try
            Paperhawk.review_add!(draft,image)
            Paperhawk.review_wait(draft)
            entry=only(draft.entries)
            @test entry.status==:error
            @test isfile(entry.source)
            @test Paperhawk.permutedims(Paperhawk.load(entry.source))==image
            @test Paperhawk.OCR_PENDING[]==baseline
        finally
            close(draft)
        end
    end
end

@testset "preview tiles retain full-resolution coordinates" begin
    mktempdir() do dir
        img=[Paperhawk.RGB{Paperhawk.N0f8}(x/160,y/200,0) for x in 1:160,y in 1:200]
        path=joinpath(dir,"page.png")
        Paperhawk.review_save_image(path,img)
        overview=Paperhawk.process_preview(path,40)
        @test size(overview.pixels)==(40,50)
        @test overview.fullsize==(160,200)
        @test overview.extent==(0,0,160,200)
        tile=Paperhawk.process_preview(path,1200,(20,30,80,90))
        @test tile.extent==(20,30,80,90)
        @test tile.pixels==img[21:80,31:90]
        @test tile.fullsize==overview.fullsize
    end
end

@testset "thread OCR priority reaches an optional classifier process" begin
    pid=Paperhawk.processing_pid()
    baseline=remotecall_fetch(()->Paperhawk.OCR_PENDING[],pid)
    requests=Channel{Any}(1)
    engine=Paperhawk.PaddleOCR(nothing,requests)
    job=@async Paperhawk.ongpu(identity,engine)
    try
        f,response=take!(requests)
        @test timedwait(()->remotecall_fetch(()->Paperhawk.OCR_PENDING[],pid)==baseline+1,5)==:ok
        put!(response,(nothing,nothing))
        fetch(job)
        @test timedwait(()->remotecall_fetch(()->Paperhawk.OCR_PENDING[],pid)==baseline,5)==:ok
    finally
        close(requests)
    end
end
