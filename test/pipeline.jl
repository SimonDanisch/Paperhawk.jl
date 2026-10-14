# The cleaned page is shown as soon as it exists, before the words are read.
@testset "image feedback before OCR completes" begin
    image=fill(RGB{N0f8}(1,1,1),160,220)
    image[30:130,80:90].=RGB{N0f8}(0.1,0.1,0.1)
    ocr=PaddleOCR()
    try
        shown=Ref{Any}(nothing)
        result=Paperhawk.prepare_page_image(image;ocr,image_ready=img->(shown[]=copy(img)))
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

@testset "background GPU work yields to OCR" begin
    Paperhawk.Threads.atomic_add!(Paperhawk.OCR_PENDING,1)
    ready=Ref(false)
    task=@async begin
        Paperhawk.wait_for_ocr()
        ready[]=true
    end
    try
        sleep(0.02)
        @test !ready[]
    finally
        Paperhawk.Threads.atomic_sub!(Paperhawk.OCR_PENDING,1)
    end
    wait(task)
    @test ready[]
end

@testset "background GPU work waits for capture and queued OCR" begin
    Threads.atomic_add!(Paperhawk.SCAN_ACTIVE,1)
    Threads.atomic_add!(Paperhawk.OCR_PENDING,1)
    task=@async Paperhawk.wait_for_ocr()
    scanning=true
    try
        sleep(0.02)
        @test !istaskdone(task)
        Threads.atomic_sub!(Paperhawk.SCAN_ACTIVE,1)
        scanning=false
        sleep(0.02)
        @test !istaskdone(task) # pausing capture alone must not delay queued OCR
    finally
        scanning && Threads.atomic_sub!(Paperhawk.SCAN_ACTIVE,1)
        Threads.atomic_sub!(Paperhawk.OCR_PENDING,1)
    end
    @test timedwait(()->istaskdone(task),5)==:ok
    fetch(task)
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
