# DISPLAY=:1 tools/bounded-julia --startup-file=no --project=. tools/test_glmakie.jl [--keep-open | --gui-only]
include("benchmark_limits.jl")
benchmark_memory_limit()
flush(stdout)
using Paperhawk, GLMakie, Test
include(joinpath(@__DIR__,"..","test","gui.jl"))
flush(stdout)
GLMakie.closeall()
GC.gc()
ccall(:malloc_trim,Cint,(Csize_t,),0)

function test_native_ocr()
    ocr=PaddleOCR()
    ui=nothing
    try
        dir=mktempdir(joinpath(@__DIR__,"..","gen");prefix="glmakie-demo-")
        ui=scanner_gui(;dir,duplex=false,ocr)
        ui.message[]="Beispielbrief · GPU-OCR · Kamera nicht verbunden"
        screen=display(GLMakie.Screen(;title="Paperhawk · GLMakie",scalefactor=1,px_per_unit=1),ui.figure)
        image=Paperhawk.review_load_image(joinpath(@__DIR__,"..","gen","gui-demo-letter.png"))
        review_add!(ui.draft,image)
        review_wait(ui.draft)
        @testset "GPU OCR in native window" begin
            @test only(ui.draft.entries).status==:ready
            @test length(only(ui.draft.entries).words)>50
            @test isopen(screen)
            @test !startswith(ui.message[],"Fehler:")
        end
        sleep(2)
        out=joinpath(@__DIR__,"..","gen","scanner-glmakie-current.png")
        Paperhawk.save(out,GLMakie.colorbuffer(screen))
        memory=join(filter(l->occursin(r"^Vm(RSS|Data|HWM|Size):",l),split(read("/proc/self/status",String),'\n')),'\n')
        result=(;display=ENV["DISPLAY"],backend="GLMakie",gui_tests=55,
            words=length(only(ui.draft.entries).words),screenshot=abspath(out),memory,
            includes="native window rendering, controls, OCR word click/edit, GPU processing of sample letter",
            excludes="real camera, Bonsai concurrency")
        open(joinpath(@__DIR__,"..","gen","glmakie-test-2026-10-12.json"),"w") do io
            Paperhawk.JSON3.pretty(io,result)
        end
        println(result);flush(stdout)
        "--keep-open" in ARGS && wait(screen)
    finally
        ui===nothing || close(ui)
        close(ocr)
        close_processing!()
    end
end

"--gui-only" in ARGS || test_native_ocr()
