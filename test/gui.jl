# GLMakie interaction smoke test; run in the main project on a local display:
# using Test, Paperhawk, GLMakie; include("test/gui.jl")
using Test, Paperhawk, GLMakie

@testset "native window lifecycle" begin
    mktempdir() do dir
        for from_window in (true,false)
            draft=ReviewSession(joinpath(dir,string(from_window));processor=(args...)->error("unused"))
            ui=scanner_gui(;draft)
            screen=GLMakie.Screen(;visible=true,title="Paperhawk · Fenstertest",scalefactor=1,px_per_unit=1)
            try
                display(screen,ui.figure)
                @test isopen(screen)
                @test !ui.closed
                @test size(GLMakie.colorbuffer(screen))==(1000,1600)
                right=only(filter(x->x isa Axis && x.title[]=="Aufnahme · zoomen und Text prüfen",ui.figure.content))
                left=only(filter(x->x isa Axis && x.title[]=="Live · Blattrand prüfen",ui.figure.content))
                for (width,height) in ((1280,800),(1920,1080))
                    GLMakie.GLFW.SetWindowSize(screen.glscreen,width,height)
                    sleep(0.2)
                    @test right.scene.viewport[].widths[2]>0.58height
                    @test right.scene.viewport[].widths[2]>2left.scene.viewport[].widths[2]
                    @test all(ui.figure.content) do block
                        hasproperty(block,:layoutobservables) || return true
                        box=block.layoutobservables.computedbbox[]
                        all(box.origin .>= -1) && all(box.origin.+box.widths .<= [width,height].+1)
                    end
                end
                from_window ? close(screen) : close(ui)
                @test ui.closed
                @test !isopen(screen)
                @test istaskdone(draft.worker)
            finally
                close(ui)
                close(screen)
            end
        end
    end
end

@testset "scanner GUI actions" begin
    mktempdir() do dir
        function process(src,corners,rotation,out)
            img=Paperhawk.permutedims(Paperhawk.load(src))
            angle=something(rotation,0)
            Paperhawk.save(out,Paperhawk.permutedims(turn(img,angle)))
            (words=[Paperhawk.Word("Rechnung",10,15,60,12,15,12,70f0)],blank=false,rotation=angle)
        end
        archive=DocumentArchive(joinpath(dir,"archive"))
        draft=ReviewSession(joinpath(dir,"draft");duplex=false,processor=process)
        ui=scanner_gui(;draft,archive)
        click(key)=(ui.buttons[key].clicks[]+=1)
        try
            left=only(filter(x->x isa Axis && x.title[]=="Live · Blattrand prüfen",ui.figure.content))
            shown_live()=left.scene.plots[1][3][]
            for color in (Paperhawk.RGB{Paperhawk.N0f8}(1,0,0),Paperhawk.RGB{Paperhawk.N0f8}(0,0,1))
                lock(ui.frame_lock) do
                    ui.latest=(image=fill(color,80,60),state=:captured,paused=true,error="",captured=0)
                end
                @test timedwait(()->size(shown_live())==(60,80) && all(==(color),shown_live()),5)==:ok
            end
            baseline=Paperhawk.SCAN_ACTIVE[]
            ui.running[]=true
            click(:pause)
            @test Paperhawk.SCAN_ACTIVE[]==baseline+1
            click(:pause)
            @test Paperhawk.SCAN_ACTIVE[]==baseline
            ui.running[]=false
            id=review_add!(draft,fill(Paperhawk.RGB{Paperhawk.N0f8}(0.6,0.6,0.6),100,140))
            review_wait(draft);ui.selected[]=id;sleep(0.3)
            @test !startswith(ui.message[],"Fehler:")
            sidemenu=only(filter(x->x isa Menu,ui.figure.content))
            @test sidemenu.selection[]==:none
            sidemenu.i_selected[]=2
            @test only(draft.entries).side==:front
            click(:undo)
            @test only(draft.entries).side==:single
            right=only(filter(x->x isa Axis && x.title[]=="Aufnahme · zoomen und Text prüfen",ui.figure.content))
            wordbox=only(filter(x->x isa Textbox && occursin("Wort im Bild",x.placeholder[]),ui.figure.content))
            function click_image(point)
                pixel=GLMakie.Makie.project(right.scene,Point2f(point)) + right.scene.viewport[].origin
                events(right).mouseposition[]=Tuple(Float64.(pixel))
                events(right).mousebutton[]=GLMakie.Makie.MouseButtonEvent(Mouse.left,Mouse.press)
                events(right).mousebutton[]=GLMakie.Makie.MouseButtonEvent(Mouse.left,Mouse.release)
            end
            sleep(0.3)
            click_image((30,20))
            @test wordbox.displayed_string[]=="Rechnung"
            wordbox.stored_string[]="Rechnung korrigiert"
            @test only(only(draft.entries).words).text=="Rechnung korrigiert"
            click(:undo)
            @test only(only(draft.entries).words).text=="Rechnung"
            click(:textzoom)
            @test right.finallimits[].widths[2]<140
            click(:fit)
            @test right.yreversed[] && right.finallimits[].widths[2]≈140
            @test all(ui.figure.content) do block
                hasproperty(block,:layoutobservables) || return true
                box=block.layoutobservables.computedbbox[]
                all(box.origin .>= 0) && all(box.origin.+box.widths .<= [1600,1000])
            end
            click(:rotate);click(:rotate);review_wait(draft)
            @test only(draft.entries).detected_rotation==180
            click(:undo);review_wait(draft)
            @test only(draft.entries).detected_rotation==90
            click(:include)
            @test !only(draft.entries).included
            click(:undo)
            @test only(draft.entries).included
            click(:crop)
            @test occursin("anklicken",ui.message[])
            click(:crop);sleep(0.3)
            @test ui.message[]=="Zuschnitt abgebrochen."
            click(:delete);sleep(0.3)
            @test isempty(draft.entries) && ui.selected[]==0
            click(:undo);review_wait(draft);sleep(0.3)
            @test ui.selected[]==id && length(draft.entries)==1
            click(:commit)
            @test timedwait(()->startswith(ui.message[],"Archiviert:") || startswith(ui.message[],"Fehler:"),15)==:ok
            @test startswith(ui.message[],"Archiviert:")
            @test only(search_documents(archive,"Rechnung"))["number"]==1
            click(:delete)
            @test startswith(ui.message[],"Fehler:") && length(draft.entries)==1
        finally
            close(ui);close(archive)
        end
    end
end

@testset "slow preview cannot block controls or replace a newer selection" begin
    mktempdir() do dir
        process(src,corners,rotation,out)=begin
            cp(src,out;force=true)
            (words=Paperhawk.Word[],blank=false,rotation=0)
        end
        draft=ReviewSession(dir;duplex=false,processor=process)
        red=fill(Paperhawk.RGB{Paperhawk.N0f8}(1,0,0),100,140)
        blue=fill(Paperhawk.RGB{Paperhawk.N0f8}(0,0,1),100,140)
        a=review_add!(draft,red);b=review_add!(draft,blue);review_wait(draft)
        entered,release=Channel{Bool}(1),Channel{Bool}(1)
        calls=Threads.Atomic{Int}(0)
        loader(path,width,area)=begin
            if width==1200 && Threads.atomic_add!(calls,1)==0
                put!(entered,true);take!(release)
            end
            pixels=Paperhawk.permutedims(Paperhawk.load(path))
            (pixels=pixels,extent=(0,0,100,140),fullsize=(100,140))
        end
        ui=scanner_gui(;draft,image_loader=loader)
        ui.selected[]=a
        right=only(filter(x->x isa Axis && x.title[]=="Aufnahme · zoomen und Text prüfen",ui.figure.content))
        shown()=right.scene.plots[1][3][]
        try
            @test timedwait(()->isready(entered),10)==:ok
            ui.buttons[:next].clicks[]+=1
            @test ui.selected[]==b
            @test timedwait(()->shown()==blue,10)==:ok
            @test right.yreversed[] # fresh image limits must retain top-left coordinates
            put!(release,true);sleep(0.2)
            @test ui.selected[]==b && shown()==blue
        finally
            isready(release) || put!(release,true)
            close(ui);empty!(ui.figure)
        end
    end
end
