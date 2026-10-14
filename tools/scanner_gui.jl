# DISPLAY=:1 tools/bounded-julia --startup-file=no --project=. tools/scanner_gui.jl [--torch] [draft-dir] [archive-dir]
include("ada4000.jl")
using Paperhawk, GLMakie

function run_scanner_gui(args=ARGS)
    camera_torch="--torch" in args
    args=filter(!=("--torch"),args)
    scanner_check_ada!()
    ocr=PaddleOCR()
    archive=nothing;ui=nothing
    try
        archive=DocumentArchive(length(args)>=2 ? args[2] : "mein-archiv")
        options=isempty(args) ? (;) : (;dir=args[1])
        ui=scanner_gui(;archive,ocr,duplex=true,camera_torch,options...)
        screen=display(GLMakie.Screen(;title="Paperhawk · Erfassen & prüfen"),ui.figure)
        GLMakie.GLFW.MaximizeWindow(screen.glscreen)
        wait(screen)
    finally
        ui===nothing || close(ui)
        archive===nothing || close(archive)
        close(ocr)
        close_processing!()
    end
end

run_scanner_gui()
