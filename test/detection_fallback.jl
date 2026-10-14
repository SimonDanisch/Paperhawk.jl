rgb(img::AbstractMatrix{<:Real}) = map(v -> RGB{N0f8}(clamp(v, 0, 1), clamp(v, 0, 1), clamp(v, 0, 1)), img)
rgb(img::AbstractMatrix{<:AbstractRGB}) = map(c -> RGB{N0f8}(clamp(red(c), 0, 1), clamp(green(c), 0, 1), clamp(blue(c), 0, 1)), img)

@testset "local contrast under uneven lighting" begin
    w,h=900,650
    truth=(Vec2f(170,100),Vec2f(730,100),Vec2f(730,540),Vec2f(170,540))
    # The desk on the right is brighter than the paper on the left.
    # There is no chromatic cue, and the top/bottom edges are slightly wavy.
    # Known gap: one threshold on whiteness for the whole frame cannot split
    # this; the sheet is only found with the torch's even light or a coloured desk.
    image=Matrix{Float32}(undef,w,h)
    for y in 1:h, x in 1:w
        edge=2sin(Float32(x)/27)
        sheet=170<=x<=730 && 100+edge<=y<=540+edge
        v=0.22f0+0.45f0*x/w+(sheet ? 0.14f0 : 0f0)
        image[x,y]=(sheet && 210<x<680 && 150<y<490 && mod(y,31)<2 && mod(x,23)<13) ? 0.16f0 : v
    end
    for scale in (1f0,0.8f0)
        page=findsheet(rgb(scale.*image))
        @test_broken page!==nothing
        page===nothing || @test maximum(norm.(page.corners.-truth))<10
    end
    desk=Float32[0.22f0+0.45f0*x/w+0.01f0*sin(y/9) for x in 1:w,y in 1:h]
    @test findsheet(rgb(desk))===nothing
end

@testset "neutral paper on a brighter colored desk" begin
    w,h=900,650
    truth=(Vec2f(170,100),Vec2f(730,100),Vec2f(730,540),Vec2f(170,540))
    desk=[RGB{Float32}(0.82f0+0.02f0*sin(x/8),0.76f0+0.02f0*sin(x/8),0.62f0+0.02f0*sin(x/8)) for x in 1:w,y in 1:h]
    image=copy(desk)
    image[170:730,100:540].=RGB{Float32}(0.72f0,0.72f0,0.74f0)
    for y in 150:25:490,x in 210:680
        mod(x,23)<13 && (image[x,y]=RGB{Float32}(0.2f0,0.2f0,0.2f0))
    end
    for input in (image,0.8f0.*image)
        page=findsheet(rgb(input))
        @test page!==nothing
        page===nothing || @test maximum(norm.(page.corners.-truth))<3
    end
    @test findsheet(rgb(desk))===nothing
    @test findsheet(rgb(fill(RGB{Float32}(0.72,0.72,0.74),w,h)))===nothing
end
