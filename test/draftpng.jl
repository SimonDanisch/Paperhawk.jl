@testset "draft PNG storage without full-page transposes" begin
    mktempdir() do dir
        file=joinpath(dir,"Seite ä.png")
        rgb=[RGB{N0f8}(x/17,y/23,(x+y)/40) for x in 1:17,y in 1:23]
        for img in (rgb,Gray{N0f8}.(rgb),rgb[1:1,:],rgb[:,1:1])
            before=copy(img)
            Paperhawk.review_save_image(file,img)
            @test permutedims(load(file))==img
            @test Paperhawk.review_load_image(file)==RGB{N0f8}.(img)
            @test img==before
        end
        # Decode PNGFiles output too: old drafts remain readable.
        Paperhawk.PNGFiles.save(file,permutedims(rgb))
        @test Paperhawk.review_load_image(file)==rgb
        @test_throws ErrorException Paperhawk.review_save_image(joinpath(dir,"missing","page.png"),rgb)
        @test_throws ErrorException Paperhawk.review_load_image(joinpath(dir,"missing.png"))
        write(file,"invalid PNG")
        @test_throws ErrorException Paperhawk.review_load_image(file)
        @test_throws ArgumentError Paperhawk.review_save_image(file,rgb[1:0,:])
        @test_throws ArgumentError Paperhawk.review_load_image("bad\0path")
        # Only the decoder's result owns a full page; writing borrows its input.
        large=repeat(rgb,40,40)
        Paperhawk.review_save_image(file,large)
        Paperhawk.review_load_image(file)
        @test @allocated(Paperhawk.review_save_image(file,large))<64_000
        @test @allocated(Paperhawk.review_load_image(file))<sizeof(large)+64_000
        buffer=similar(large)
        @test Paperhawk.review_load_image(file;buffer)===buffer
        @test buffer==large
        @test @allocated(Paperhawk.review_load_image(file;buffer))<64_000
        @test Paperhawk.review_load_image(file;buffer=rgb)==large
    end
end

@testset "preview cache reuses pixels without changing delivered tiles" begin
    previews=Paperhawk.Previews()
    try
        mktempdir() do dir
            tiles=Any[];identities=Set{UInt}()
            for k in 1:12
                path=joinpath(dir,"$k.png")
                image=fill(RGB{N0f8}(k/20,0.2,0.3),64,96)
                Paperhawk.review_save_image(path,image)
                push!(tiles,Paperhawk.tile(previews,path,32))
                Paperhawk.pixels(previews,path) do pixels
                    push!(identities,objectid(pixels))
                end
            end
            # Four decoded pages are kept, their buffers reused for the next.
            @test length(identities)==4
            for k in 1:12
                @test all(==(RGB{N0f8}(k/20,0.2,0.3)),tiles[k].pixels)
            end
        end
    finally
        close(previews)
    end
end
