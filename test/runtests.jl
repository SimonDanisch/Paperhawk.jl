using Paperhawk, Test, ImageCore, FileIO, LinearAlgebra, Random
using Paperhawk: homography, project, Page, Camera, update!, PageDetector, detect!, thumbnail
using GeometryBasics: Vec2f

text_lines(u, v) = 30 < v < 270 && 20 < u < 190 && mod(v, 8) < 2.5 && mod(u * 1.3f0, 9) > 2

"""
    synthetic_frame(corners; size, rng, samples, dark) -> Matrix{RGB{N0f8}}

A dark, unevenly lit desk with a white sheet whose corners are exactly
`corners` (top-left first, clockwise on screen), dark where `dark(u, v)` is
true for the sheet's coordinates in millimetres (lines of "text" by default),
edges antialiased by supersampling, and a little sensor noise.
"""
function synthetic_frame(corners; size = (4624, 3472), rng = Xoshiro(1), samples = 3, dark = text_lines)
    w, h = size
    # Sheet coordinates (0..210, 0..297 mm) to frame coordinates.
    sheet = (Vec2f(0, 0), Vec2f(210, 0), Vec2f(210, 297), Vec2f(0, 297))
    H = homography(corners, sheet)
    img = Matrix{RGB{N0f8}}(undef, w, h)
    offsets = [(i - 0.5f0) / samples - 0.5f0 for i in 1:samples]
    Threads.@threads for y in 1:h
        for x in 1:w
            acc = 0.0f0
            for oy in offsets, ox in offsets
                p = project(H, Vec2f(x + ox, y + oy))
                inside = 0 <= p[1] <= 210 && 0 <= p[2] <= 297
                v = if inside
                    dark(p[1], p[2]) ? 0.15f0 : 0.9f0
                else
                    0.12f0 + 0.08f0 * x / w
                end
                acc += v
            end
            v = acc / samples^2 + 0.01f0 * randn(rng, Float32)
            img[x, y] = RGB{N0f8}(clamp(v, 0, 1), clamp(v, 0, 1), clamp(0.97v, 0, 1))
        end
    end
    return img
end

angle(a, b) = rad2deg(atan(b[2] - a[2], b[1] - a[1]))

# The detector's GPU device belongs to the thread that creates it: the main task.
const DETECTOR = PageDetector()
findsheet(img) = find_page(DETECTOR, img)

"""
    turn(img, degrees)

`img[x, y]` turned clockwise, as it is displayed, by a multiple of 90 degrees.
"""
function turn(img::AbstractMatrix, degrees::Integer)
    d = mod(degrees, 360)
    d == 0 && return img
    d == 90 && return reverse(permutedims(img); dims = 1)
    d == 180 && return reverse(img)
    d == 270 && return reverse(permutedims(img); dims = 2)
    throw(ArgumentError("can only turn by multiples of 90 degrees, not $degrees"))
end

@testset "Paperhawk" begin
    include("draftpng.jl")
    @testset "bilinear sampling at singleton borders" begin
        @test Paperhawk.sample(fill(0.3f0,1,1),-10,20)==0.3f0
        @test Paperhawk.sample(reshape(Float32[0,1],1,2),1,1.5)==0.5f0
        @test Paperhawk.sample(reshape(Float32[0,1],2,1),1.5,1)==0.5f0
    end
    @testset "a rotated, slightly tilted A4 sheet" begin
        # About 2° rotation and a little perspective, roughly the size A4 takes in the frame.
        truth = (Vec2f(1100.3, 420.7), Vec2f(3480.2, 505.1), Vec2f(3390.6, 3101.4), Vec2f(980.9, 3020.2))
        img = synthetic_frame(truth)
        page = findsheet(img)
        @test page !== nothing
        err = maximum(norm.(page.corners .- truth))
        @info "corner error" err page.edge_rms
        @test err < 1.0
        # Skew: the angle of each edge against the truth.
        skew = maximum(abs(angle(page.corners[k], page.corners[mod1(k + 1, 4)]) - angle(truth[k], truth[mod1(k + 1, 4)])) for k in 1:4)
        @info "skew in degrees" skew
        @test skew < 0.05
    end

    @testset "no sheet" begin
        rng = Xoshiro(2)
        desk = [RGB{N0f8}(v, v, v) for v in clamp.(0.15f0 .+ 0.02f0 .* randn(rng, Float32, 1200, 900), 0, 1)]
        @test findsheet(desk) === nothing
    end

    @testset "bright things that are not sheets" begin
        w, h = 1200, 900
        disk = [RGB{N0f8}(v, v, v) for v in (hypot(x - 600, y - 450) < 250 ? 0.9f0 : 0.15f0 for x in 1:w, y in 1:h)]
        @test findsheet(disk) === nothing
        ell = [RGB{N0f8}(v, v, v) for v in ((300 < x < 900 && 200 < y < 400) || (300 < x < 500 && 200 < y < 750) ? 0.9f0 : 0.15f0 for x in 1:w, y in 1:h)]
        @test findsheet(ell) === nothing
    end

    @testset "trigger: one capture per sheet" begin
        sheet(x) = Page((Vec2f(x, 0), Vec2f(x + 100, 0), Vec2f(x + 100, 140), Vec2f(x, 140)), 0.2f0, 1.0f0, 0.1f0)
        frames = [
            fill(nothing, 5);                       # 0.0-0.4 empty desk
            [sheet(50 + 10k) for k in 0:4];         # 0.5-0.9 being put down
            fill(sheet(100), 11);                   # 1.0-2.0 lying still: captured at 1.5
            [nothing];                              # 2.1 a hand passes over it
            fill(sheet(100), 9);                    # 2.2-3.0 still the same sheet
            fill(nothing, 4);                       # 3.1-3.4 taken away
            fill(sheet(200), 11)                    # 3.5-4.5 the next one: captured at 4.0
        ]
        t = Trigger()
        fired = [k / 10 for (k, page) in zip(0:(length(frames) - 1), frames) if update!(t, page, k / 10)]
        @test fired == [1.5, 4.0]
    end

    @testset "trigger: a new sheet put down on top of the last" begin
        size = (1200, 900)
        a = (Vec2f(300, 100), Vec2f(830, 110), Vec2f(820, 860), Vec2f(290, 850))
        b = map(p -> p + Vec2f(25, -12), a)
        picture(u, v) = 40 < u < 170 && 50 < v < 150
        frames = [
            (a, text_lines), (a, text_lines), (a, text_lines),   # captured
            (b, text_lines), (b, text_lines), (b, text_lines),   # the same sheet, nudged: not again
            (a, picture), (a, picture), (a, picture),            # a different sheet on top: captured
        ]
        images = Dict(f => synthetic_frame(f[1]; size, dark = f[2]) for f in unique(frames))
        t = Trigger(; hold = 0.15)
        fired = Int[]
        for (k, f) in enumerate(frames)
            img = images[f]
            update!(t, detect!(DETECTOR, img), k / 10) && push!(fired, k)
        end
        @test fired == [3, 9]
    end

    include("trigger.jl")

    @testset "a sheet that runs off the frame" begin
        truth = (Vec2f(-200, 300), Vec2f(900, 320), Vec2f(880, 850), Vec2f(-220, 830))
        @test findsheet(synthetic_frame(truth; size = (1200, 900))) === nothing
    end

    include("detection_fallback.jl")
    include("documents.jl")
    include("archive.jl")
    include("database.jl")
    include("review.jl")
    include("pipeline.jl")
    try
        include("processing.jl")
    finally
        Paperhawk.close_processing!()
    end
end
