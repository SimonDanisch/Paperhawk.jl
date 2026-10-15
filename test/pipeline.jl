# The cleaned page is shown as soon as it exists, before the words are read.
@testset "image feedback before OCR completes" begin
    image=fill(RGB{N0f8}(1,1,1),160,220)
    image[30:130,80:90].=RGB{N0f8}(0.1,0.1,0.1)
    ocr=PaddleOCR()
    try
        shown=Ref{Any}(nothing)
        result=process_page(ocr,image;image_ready=img->(shown[]=copy(img)))
        # image_ready runs on the GPU thread before recognition, with the final pixels.
        @test shown[]==result.image
        mktempdir() do dir
            s=ReviewSession(dir;duplex=false,ocr)
            try
                review_add!(s,image);review_wait(s)
                entry=only(s.entries)
                @test entry.status==:ready
                @test isfile(entry.output)
                @test permutedims(load(entry.source))==image
            finally
                close(s)
                @test !isopen(s.capture_buffers) && !isready(s.capture_buffers)
            end
        end
    finally
        close(ocr)
    end
end

@testset "background GPU work yields to foreground demand" begin
    # Capture and a queued page each hold the demand; background work goes on
    # only when both have let go.
    demand=Threads.Atomic{Int}(0)
    Threads.atomic_add!(demand,1) # the camera is capturing
    Threads.atomic_add!(demand,1) # a page is queued
    task=@async Paperhawk.yield_to(demand)
    sleep(0.02)
    @test !istaskdone(task)
    Threads.atomic_sub!(demand,1) # capture paused
    sleep(0.02)
    @test !istaskdone(task) # the queued page still comes first
    Threads.atomic_sub!(demand,1)
    @test timedwait(()->istaskdone(task),5)==:ok
    fetch(task)
    # Without an engine to give way to, background work never waits.
    @test Paperhawk.yield_to(nothing)===nothing
end

@testset "a queued page holds the engine's demand until it is read" begin
    ocr=PaddleOCR()
    release=Channel{Nothing}(1)
    try
        mktempdir() do dir
            s=ReviewSession(dir;duplex=false,ocr)
            try
                # Keep the engine busy with a request that is not demand itself.
                busy=Threads.@spawn Paperhawk.ongpu(_->take!(release),ocr.worker)
                review_add!(s,fill(RGB{N0f8}(1,1,1),160,220))
                @test timedwait(()->ocr.demand[]>=1,5)==:ok
                put!(release,nothing);fetch(busy)
                review_wait(s)
                @test ocr.demand[]==0
                @test only(s.entries).status==:ready
            finally
                close(s)
            end
        end
    finally
        isready(release) || put!(release,nothing)
        close(ocr)
    end
end

@testset "capture buffers are bounded and originals survive reuse" begin
    mktempdir() do dir
        entered=Channel{Nothing}(8);release=Channel{Nothing}(8)
        processor=(src,corners,rotation,out)->begin
            put!(entered,nothing);take!(release)
            cp(src,out;force=true)
            (words=Word[],blank=false,rotation=0)
        end
        s=ReviewSession(dir;duplex=false,processor,workers=2)
        extra=nothing
        try
            for k in 1:4
                review_add!(s,fill(RGB{N0f8}(k/10,0.2,0.3),100,140))
            end
            extra=@async review_add!(s,fill(RGB{N0f8}(0.5,0.2,0.3),100,140))
            sleep(0.05)
            @test !istaskdone(extra)
            @test length(s.entries)==4
            for _ in 1:5;put!(release,nothing);end
            fetch(extra);review_wait(s)
            @test length(s.entries)==5
            for k in 1:5
                @test all(==(RGB{N0f8}(k/10,0.2,0.3)),load(s.entries[k].source))
            end
            buffers=[take!(s.capture_buffers) for _ in 1:4]
            @test length(unique(objectid.(buffers)))==4
            foreach(b->put!(s.capture_buffers,b),buffers)
        finally
            for _ in 1:5
                isready(release) || put!(release,nothing)
                yield()
            end
            extra===nothing || wait(extra)
            close(s)
        end
    end
end
