# Frame content matters even when a sheet is put down in exactly the same place.
# Thumbnails come from the GPU detector, for the whole image as the sheet.
@testset "fast sheet changes" begin
    corners = (Vec2f(1,1), Vec2f(240,1), Vec2f(240,340), Vec2f(1,340))
    page = Page(corners, 1f0, 1f0, 0f0)
    a = [RGB{N0f8}(20 < x < 210 && 40 < y < 300 && mod(y,20) < 4 ? 0.1 : 0.95) for x in 1:240, y in 1:340]
    b = [RGB{N0f8}(40 < x < 160 && 60 < y < 190 ? 0.1 : 0.95) for x in 1:240, y in 1:340]
    c = [RGB{N0f8}(80 < x < 220 && 140 < y < 310 ? 0.1 : 0.95) for x in 1:240, y in 1:340]
    function captures(frames; trigger = Trigger(hold=0.15))
        [i for (i,img) in enumerate(frames) if img === nothing ? update!(trigger, nothing, i/10) :
            update!(trigger, page, i/10; thumbnail = thumbnail(DETECTOR, img, page))]
    end
    @test captures([a,a,a,a,b,b,b,b]) == [3,7]
    @test captures([a,a,a,b,c,b,c,b,b,b]) == [3,10]
    @test captures([a,a,a,b,a,a,a,a]) == [3]  # brief hand/occlusion, original returns
    @test captures([a,a,nothing,a,a,a]) == [6] # no capture immediately after a detection gap
    @test captures([a,a,a,nothing,nothing,nothing,a,a,a]) == [3] # detection lost, same sheet: never twice
    @test captures([a,a,a,nothing,nothing,nothing,b,b,b]) == [3,9] # removed, next sheet
    exposures = [map(p -> RGB{N0f8}(0.8f0*red(p)+0.1f0), a) for _ in 1:4]
    @test captures([a,a,a,exposures...]) == [3]

    # Blank paper with fresh sensor noise in every frame must neither keep
    # restarting the stability timer nor be mistaken for a new blank sheet.
    rng = Xoshiro(2026)
    blanks = [[RGB{N0f8}(clamp(0.9f0 + 0.01f0*randn(rng,Float32),0,1)) for x in 1:240, y in 1:340] for _ in 1:12]
    @test captures(blanks) == [3]
    @test captures([a,a,a,blanks...]) == [3,6]
end
