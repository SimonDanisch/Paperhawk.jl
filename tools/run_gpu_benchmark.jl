# Run with tools/bounded-julia --startup-file=no --project=. tools/run_gpu_benchmark.jl
# A standalone app measurement: no Revise, MCP bridge, or accumulated test state.
include("benchmark_limits.jl")
benchmark_memory_limit()
using Paperhawk, GLMakie
include("profile_review.jl")

function run_gpu_benchmark()
    ocr=PaddleOCR()
    try
        image=Paperhawk.review_load_image(joinpath(@__DIR__,"..","gen","gui-demo-letter.png"))
        gui=benchmark_ui(image,ocr;pages=30)
        println((gui=gui,))
        gui_long=benchmark_ui(image,ocr;pages=120)
        println((gui_long=gui_long,))
        review=[benchmark_review(image,ocr) for _ in 1:3]
        println((review=review,))
        feedback=benchmark_feedback(image,ocr)
        println((feedback=feedback,))
        memory=join(filter(l->occursin(r"^Vm(RSS|Size|Data|HWM):",l),
            split(read("/proc/self/status",String),'\n')),'\n')
        println(memory)
        data=(;gui,gui_long,review,feedback,memory,execution="standalone launcher",
            julia=string(VERSION),cpu=first(Sys.cpu_info()).model,
            dimensions=size(image),heap_hint="2G",gc_threads="8,1",
            malloc_arenas=ENV["MALLOC_ARENA_MAX"],mmap_threshold=ENV["MALLOC_MMAP_THRESHOLD_"],
            data_limit=6*1024^3,address_limit=12*1024^3,
            includes="native GLMakie rendering, original PNG, cleanup, orientation, OCR, processed PNG; simulated camera frames",
            excludes="camera transfer, edge detection, UVDoc, PDF export, Bonsai")
        open(joinpath(@__DIR__,"..","gen","gpu-pipeline-glmakie-2026-10-12.json"),"w") do io
            Paperhawk.JSON3.pretty(io,data)
        end
    finally
        close(ocr)
        close_processing!()
    end
end

run_gpu_benchmark()

# Optional cheap persistence checks after measurement, using the same code.
if "--check-review" in ARGS
    using Test, ImageCore, FileIO
    include(joinpath(@__DIR__,"..","test","review.jl"))
end
