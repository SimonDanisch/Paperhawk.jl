# Native layout preview using a saved OCR result; no model loading.
# DISPLAY=:1 tools/bounded-julia --startup-file=no --project=. tools/preview_gui.jl
include("benchmark_limits.jl")
benchmark_memory_limit();flush(stdout)
using Paperhawk, GLMakie

function preview_gui()
    root=abspath(joinpath(@__DIR__,".."))
    dir=mktempdir(joinpath(root,"gen");prefix="layout-preview-")
    cp(joinpath(root,"scans","gui-demo","draft.json"),joinpath(dir,"draft.json"))
    control=joinpath(root,"gen","gui-preview-command.txt")
    write(control,"")
    ui=nothing
    source=joinpath(root,"ext","PaperhawkMakieExt.jl")
    modified=mtime(source)
    function open_ui()
        draft=ReviewSession(dir;processor=(args...)->error("Gespeicherte Beispielaufnahme; keine Kamera verbunden"))
        ui=scanner_gui(;draft)
        ui.message[]="Beispielaufnahme · Kamera nicht verbunden"
        screen=display(GLMakie.Screen(;title="Paperhawk · Layout",scalefactor=1,px_per_unit=1),ui.figure)
        (ui,screen)
    end
    try
        ui,screen=open_ui()
        sleep(2)
        Paperhawk.save(joinpath(root,"gen","scanner-layout-window.png"),GLMakie.colorbuffer(screen))
        println("PREVIEW READY");flush(stdout)
        while isopen(screen)
            sleep(0.2)
            if mtime(source)!=modified
                close(ui);empty!(ui.figure);GC.gc()
                code=readlines(source)
                firstline=findfirst(l->startswith(l,"function A.scanner_gui("),code)
                Base.include_string(Base.get_extension(Paperhawk,:PaperhawkMakieExt),join(code[firstline:end-1],'\n'),source)
                modified=mtime(source)
                ui,screen=Base.invokelatest(open_ui)
                sleep(2)
                Paperhawk.save(joinpath(root,"gen","scanner-layout-window.png"),GLMakie.colorbuffer(screen))
                println("PREVIEW UPDATED");flush(stdout)
            end
            command=strip(read(control,String))
            isempty(command) && continue
            write(control,"")
            if command=="quit"
                break
            elseif command=="fullscreen"
                ui.buttons[:fullscreen].clicks[]+=1
            elseif command=="text"
                ui.buttons[:textzoom].clicks[]+=1
            elseif command=="fit"
                ui.buttons[:fit].clicks[]+=1
            elseif startswith(command,"resize ")
                width,height=parse.(Int,split(command)[2:3])
                GLMakie.GLFW.SetWindowSize(screen.glscreen,width,height)
            end
            sleep(1.5)
            path=joinpath(root,"gen",command=="text" ? "scanner-layout-text.png" : "scanner-layout-current.png")
            Paperhawk.save(path,GLMakie.colorbuffer(screen))
            println((command=command,screenshot=path,size=size(GLMakie.colorbuffer(screen))));flush(stdout)
        end
    finally
        ui===nothing || close(ui)
        close_processing!()
    end
end

preview_gui()
