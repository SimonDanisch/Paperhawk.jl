# Same-process OCR + real Bonsai, with kernel-enforced memory limits.
# DISPLAY=:1 tools/bounded-julia --startup-file=no --project=. tools/run_bonsai_benchmark.jl
include("benchmark_limits.jl")
benchmark_memory_limit()
flush(stdout)
using Paperhawk, GLMakie
include("profile_review.jl")

const DOCUMENT = """
Stadtwerke Süd GmbH
Rechnung vom 12.03.2026, Rechnungsnummer 2026-0312
Stromversorgung für März 2026. Gesamtbetrag 89,50 EUR.
Bitte überweisen Sie den Rechnungsbetrag bis zum 26.03.2026.
"""

function memory_snapshot()
    status=join(filter(l->occursin(r"^Vm(RSS|Size|Data|HWM):",l),
        split(read("/proc/self/status",String),'\n')),'\n')
    vram=Dict(path=>parse(Int,strip(read(path,String))) for path in
        ["/sys/class/drm/card0/device/mem_info_vram_used",
         "/sys/class/drm/card1/device/mem_info_vram_used"] if isfile(path))
    (;status,vram)
end

function validate_classification(result)
    m=result.metadata
    @assert m["category"]=="Rechnungen"
    @assert m["sender"]=="Stadtwerke Süd GmbH"
    @assert m["date"]=="2026-03-12"
    @assert !isempty(m["summary"])
end

function run_bonsai_benchmark()
    ocr=PaddleOCR()
    classifier=nothing
    rows=Any[]
    automatic="--automatic" in ARGS
    output=joinpath(@__DIR__,"..","gen",automatic ?
        "bonsai-automatic-glmakie-2026-10-12.json" : "bonsai-concurrent-glmakie-2026-10-12.json")
    function record(label,result)
        row=(;label,result,memory=memory_snapshot())
        push!(rows,row)
        println(row);flush(stdout)
        open(output,"w") do io
            Paperhawk.JSON3.pretty(io,(;julia=string(VERSION),rows,
                data_limit=6*1024^3,address_limit=12*1024^3,
                execution="same-process sticky GPU thread; bounded-julia",
                gui_events=automatic ? "main-thread dispatch; no navigation during automatic capture" : "real Next button",
                includes="native GLMakie rendering, simulated camera frames, original/processed PNG, cleanup, orientation, OCR; real Bonsai invoice classification",
                excludes="real camera, UVDoc, PDF/database writes"))
        end
    end
    try
        image=Paperhawk.review_load_image(joinpath(@__DIR__,"..","gen","gui-demo-letter.png"))
        record("ocr_only",benchmark_ui(image,ocr;pages=30,automatic))
        println("Loading real Bonsai on OCR device/thread");flush(stdout)
        classifier=BonsaiClassifier(ocr)
        record("models_loaded",nothing)
        for i in 1:2
            started=time_ns()
            result=classifier(DOCUMENT,Paperhawk.DEFAULT_CATEGORIES)
            validate_classification(result)
            record("classification_alone_$i",(;elapsed=(time_ns()-started)/1e9,metadata=result.metadata))
        end
        record("bonsai_resident_idle",benchmark_ui(image,ocr;pages=30,automatic))
        automatic && record("bonsai_resident_idle_120",benchmark_ui(image,ocr;pages=120,automatic))
        for pages in (30,120)
            result=benchmark_ui(image,ocr;pages,classifier,text=DOCUMENT,automatic)
            @assert result.classification_pending_at_scan_start
            validate_classification(result.classification)
            record("concurrent_$pages",result)
        end
        record("after_concurrent_idle",benchmark_ui(image,ocr;pages=30,automatic))
    finally
        classifier===nothing || close(classifier)
        close(ocr)
        close_processing!()
    end
end

run_bonsai_benchmark()
