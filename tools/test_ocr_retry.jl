# Include in a bounded Julia process, then call on the OCR model's owning thread.
using Paperhawk, Test

function check_ocr_width_retry(reader)
    model=reader.model
    A=Paperhawk
    image=A.permutedims(A.load(joinpath(@__DIR__,"..","test","fixtures","ocr-curved-footer.png")))
    expected="Diese Rechnung wurde maschinell erstellt und ist ohne Unterschrift gültig"
    s=A.gpu_workspace(reader,image)
    A.gpu_upload!(s,image)
    pixels=A.GM.storage(s.buffers[:page])
    box=(0f0,0f0,Float32(size(image,1)),Float32(size(image,2)))
    @testset "Curved footer OCR width retry" begin
        narrow=A.gpu_recognize(s,model,pixels,box;retry=false)
        @test narrow.score<0.8f0
        corrected=A.gpu_recognize(s,model,pixels,box)
        @test corrected.text==expected
        @test corrected.score>0.95f0
        @test corrected.box==box
        @test all(0<=a<=b<=size(image,1) for (_,a,b) in corrected.words)
        @test join(first.(corrected.words)," ")==expected
        # Wider inference must not leave its scale/input in the original plan.
        @test A.gpu_recognize(s,model,pixels,box;retry=false).text==narrow.text
        bytes=A.GM.reserved(A.GM.pool(model.det.device))
        elapsed=@elapsed for _ in 1:3
            @test A.gpu_recognize(s,model,pixels,box).text==expected
        end
        @test A.GM.reserved(A.GM.pool(model.det.device))==bytes
        println((footer_before=narrow.text,footer_after=corrected.text,
            confidence=corrected.score,retry_seconds=elapsed/3))
        flush(stdout)
    end
end
