# Run in a persistent Julia session AFTER tools/benchmark_limits.jl.
using Paperhawk, Test
import Mantle

# Clockwise, as displayed: the rotations gpu_page applies.
turn(img,d)=(d=mod(d,360); d==0 ? img : d==90 ? reverse(permutedims(img);dims=1) : d==180 ? reverse(img) : reverse(permutedims(img);dims=2))

function check_gpu_images(reader;full=false)
    model=reader.model
    A=Paperhawk
    # Runtime work is serialized by the caller on the model's owning thread.
    source=A.permutedims(A.load(joinpath(@__DIR__,"..","gen","gui-demo-letter.png")))
    image=full ? source : source[1:4:end,1:4:end]
    s=A.gpu_workspace(reader,image)
    A.gpu_upload!(s,image);A.gpu_cleanup!(s)
    @testset "GPU page processing" begin
        ref=Array(Mantle.storage(s.buffers[:flat]))
        @test all(isfinite,A.channelview(ref))
        @test A.gpu_orientation(s,model)==A.PPOCRRunner.orientation(model,ref)
        pixels=Mantle.storage(s.buffers[:flat])
        boxes=A.gpu_boxes(s,model,pixels)
        reference=A.PPOCRRunner.detect(model,ref)
        @test length(boxes)==length(reference)
        @test maximum(maximum(abs.(a.-b)) for (a,b) in zip(boxes,reference))<0.1
        @test A.gpu_recognize(s,model,pixels,first(boxes)).text==A.PPOCRRunner.recognize(model,ref,first(reference)).text
        # Kernels must overwrite scratch completely; an intervening blank must
        # not leave text or ink in the next page, and output images remain owned.
        first_result=A.gpu_page(reader,image)
        saved=copy(first_result.image)
        blank=A.gpu_page(reader,fill(A.RGB{A.N0f8}(1,1,1),size(image)))
        @test blank.blank && isempty(blank.words)
        black=A.gpu_page(reader,fill(A.RGB{A.N0f8}(0,0,0),size(image));rotation=0,recognize=false)
        @test !black.blank && all(iszero,A.channelview(black.image))
        @test_throws ArgumentError A.gpu_page(reader,fill(A.RGB{A.N0f8}(1,1,1),20,30))
        again=A.gpu_page(reader,image)
        @test again.image==first_result.image==saved
        @test A.text(again.words)==A.text(first_result.words)
        buffer=Ref{Any}(nothing)
        lent=A.gpu_page(reader,image;output_buffer=buffer,recognize=false)
        @test lent.image===buffer[]
        wiped=A.gpu_page(reader,fill(A.RGB{A.N0f8}(1,1,1),size(image));output_buffer=buffer,recognize=false)
        @test wiped.image===lent.image
        @test wiped.blank && all(==(A.RGB{A.N0f8}(1,1,1)),wiped.image)
        @test first_result.image==saved # default outputs still own their data
        for _ in 1:2;A.gpu_page(reader,image;output_buffer=buffer);end
        borrowed_bytes=@allocated A.gpu_page(reader,image;output_buffer=buffer)
        @test borrowed_bytes<min(sizeof(image),2_000_000)
        println((borrowed_page_bytes=borrowed_bytes,))
        for rotation in (90,180,270)
            result=A.gpu_page(reader,image;rotation,recognize=false)
            @test result.image==turn(first_result.image,rotation)
        end
        for _ in 1:2;A.gpu_upload!(s,image);A.gpu_cleanup!(s);end
        buffers=Dict(k=>objectid(v) for (k,v) in s.buffers)
        plans=Dict(k=>objectid(v) for (k,v) in s.plans)
        bytes=@allocated A.gpu_cleanup!(s)
        @test bytes<16_384
        @test Dict(k=>objectid(v) for (k,v) in s.buffers)==buffers
        @test Dict(k=>objectid(v) for (k,v) in s.plans)==plans
        println((cleanup_bytes=bytes,cleanup_seconds=@elapsed(A.gpu_cleanup!(s)),size=size(image)))
    end
    nothing
end

function check_gpu_geometry(reader)
    model=reader.model
    A=Paperhawk
    @testset "GPU geometry and bounded component reduction" begin
        image=A.permutedims(A.load(joinpath(@__DIR__,"..","gen","uvdoc-book-original.jpg")))
        w,h=size(image)
        corners=(A.Vec2f(8,12),A.Vec2f(w-18,23),A.Vec2f(w-12,h-15),A.Vec2f(13,h-22))
        result=A.gpu_page(reader,image;corners,dpi=100,rotation=0,recognize=false)
        @test size(result.image)==A.paper_size(dpi=100)
        invalid=(A.Vec2f(NaN,12),corners[2],corners[3],corners[4])
        @test_throws ArgumentError A.gpu_page(reader,image;corners=invalid,dpi=100,recognize=false)
        @test_throws ArgumentError A.gpu_read_lines(reader,image[1:0,:])
        @test_throws ArgumentError A.gpu_page_orientation(reader,image[1:0,:])
        uv=A.UVDocRunner.uvdoc(;backend=model.backend)
        try
            result=A.gpu_page(reader,image;dewarper=uv,rotation=0,recognize=false)
            @test size(result.image)==size(image) && all(isfinite,A.channelview(result.image))
        finally
            close(uv)
        end
        fake=(page=(64,64),)
        s=A.GPUPageWorkspace(model,(160,220),A.RGB{A.N0f8})
        prob=Mantle.Buffer(model.det.device,Float32,(64,64,1,1))
        try
            host=zeros(Float32,64,64,1,1)
            host[3:6,3:6,1,1].=0.9f0;host[7:10,7:10,1,1].=0.9f0 # diagonal connection
            host[40:45,20:25,1,1].=0.9f0
            host[20:25,40:45,1,1].=0.4f0 # below component score threshold
            copyto!(prob,host)
            boxes=A.gpu_component_boxes(s,fake,Mantle.storage(prob),(64,64))
            @test length(boxes)==2
            @test boxes[1]==(0f0,0f0,13f0,13f0)
            @test boxes[2]==(36.75f0,16.75f0,47.25f0,27.25f0)
            for _ in 1:20
                @test A.gpu_component_boxes(s,fake,Mantle.storage(prob),(64,64))==boxes
            end
            fill!(host,0);copyto!(prob,host)
            @test isempty(A.gpu_component_boxes(s,fake,Mantle.storage(prob),(64,64)))
        finally
            close(s);Mantle.free!(prob)
        end
    end
end

function check_gpu_reuse(reader)
    model=reader.model
    A=Paperhawk
    letter=A.permutedims(A.load(joinpath(@__DIR__,"..","gen","gui-demo-letter.png")))
    book=A.permutedims(A.load(joinpath(@__DIR__,"..","gen","uvdoc-book-original.jpg")))
    w,h=size(book)
    corners=(A.Vec2f(8,12),A.Vec2f(w-18,23),A.Vec2f(w-12,h-15),A.Vec2f(13,h-22))
    pool_bytes=Int[]
    @testset "GPU workspace replacement and stable replay" begin
        for cycle in 1:6
            for (input,crop) in ((letter,nothing),(book,corners))
                result=A.gpu_page(reader,input;corners=crop,dpi=100,rotation=0,recognize=false)
                @test all(isfinite,A.channelview(result.image))
                @test size(result.image)==(crop===nothing ? size(input) : A.paper_size(dpi=100))
            end
            push!(pool_bytes,Mantle.reserved(Mantle.pool(model.det.device)))
        end
        @test maximum(pool_bytes[3:end])==minimum(pool_bytes[3:end])
        @test !isempty(A.gpu_page(reader,letter).words)
        s=reader.workspace
        buffers=Dict(k=>objectid(v) for (k,v) in s.buffers)
        plans=Dict(k=>objectid(v) for (k,v) in s.plans)
        warm=Mantle.reserved(Mantle.pool(model.det.device))
        for _ in 1:12
            A.gpu_page(reader,letter)
        end
        @test Dict(k=>objectid(v) for (k,v) in s.buffers)==buffers
        @test Dict(k=>objectid(v) for (k,v) in s.plans)==plans
        @test Mantle.reserved(Mantle.pool(model.det.device))==warm
        println((size_change_pool_bytes=pool_bytes,replay_pool_bytes=warm))
    end
end
