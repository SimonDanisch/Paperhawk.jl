# The scanner window: live view, the draft's pages, and the review controls,
# as a native GLMakie window. A module of its own, so Makie's many exported
# names do not meet Paperhawk's.
module GUI
using ..Paperhawk, GLMakie
using GLMakie.Makie: Button, Textbox, Menu, Label
using ..Paperhawk: RGB, N0f8, Vec2f, Word
import ..Paperhawk as A
const BG=RGB{Float32}(0.95,0.96,0.98)
const INK=RGB{Float32}(0.10,0.16,0.25)
const GREEN=RGB{Float32}(0.10,0.48,0.32)
const AMBER=RGB{Float32}(0.68,0.35,0.06)
const RED=RGB{Float32}(0.72,0.12,0.17)
const MUTED=RGB{Float32}(0.39,0.45,0.52)
const ACCENT=RGB{Float32}(0.12,0.36,0.51)
const CANVAS=RGB{Float32}(0.84,0.88,0.91)
const EMPTY=fill(RGB{N0f8}(0.90,0.92,0.94),480,640)
setchanged!(observable,value)=(observable[]==value || (observable[]=value);nothing)

mutable struct ScannerUI
    figure::Figure
    draft::ReviewSession
    archive::Union{Nothing,DocumentArchive}
    ocr::Union{Nothing,PaddleOCR}
    previews::A.Previews
    select::Any
    selected::Observable{Int}
    message::Observable{String}
    timer::Union{Nothing,Timer}
    camera::Any
    task::Union{Nothing,Task}
    running::Threads.Atomic{Bool}
    paused::Threads.Atomic{Bool}
    commands::Channel{Any}
    latest::Any
    frame_lock::ReentrantLock
    capture_lock::ReentrantLock
    last_capture::Threads.Atomic{Int}
    buttons::Dict{Symbol,Any}
    closed::Bool
end

# Active automatic capture is foreground demand on the OCR engine: LLM work
# on its device resumes when capture is paused and the queued OCR has drained.
function pause!(ui,value::Bool)
    previous=Threads.atomic_xchg!(ui.paused,value)
    previous==value || A.hold!(ui.ocr,value ? -1 : 1)
    value
end

function action(f,ui)
    try
        f()
    catch err
        ui.message[]="Fehler: "*A.review_error(err)
    end
end
selected_entry(ui)=A.review_entry(ui.draft,ui.selected[])
function selected_action(f,ui)
    action(ui) do
        ui.selected[]==0 && return
        pause!(ui,true)
        f(selected_entry(ui))
    end
end

function connect!(ui,cam)
    ui.camera === nothing || throw(ArgumentError("Kamera ist bereits verbunden"))
    ui.camera=cam; ui.running[]=true; pause!(ui,true)
    ui.task=errormonitor(A.spawn_gpu_owner("live view") do
        detector=A.PageDetector(;select=ui.select)
        trigger=Trigger(hold=0.3)
        img=Matrix{A.RGB{A.N0f8}}(undef,size(cam))
        try
            while ui.running[]
                # Loading the OCR models and compiling GPU kernels at startup can
                # stall the stream for several seconds; a dead decoder still fails at once.
                frame!(img,cam;timeout=30)
                detection=A.detect!(detector,img)
                page=detection.page
                lock(ui.capture_lock) do
                forced=isready(ui.commands) ? take!(ui.commands) : nothing
                fired=forced !== nothing || (!ui.paused[] && A.update!(trigger,detection,time()))
                previewframe=(image=detection.preview,outline=outline(detection),
                    state=page===nothing ? :missing : trigger.state,paused=ui.paused[],error="",captured=0)
                lock(ui.frame_lock) do
                    ui.latest=previewframe
                end
                if fired
                    mode,target=forced===nothing ? (:add,nothing) : forced
                    # Check pause once more after detection, so editing cannot
                    # accidentally add another automatic capture in the meantime.
                    forced===nothing && ui.paused[] && return
                    id=review_add!(ui.draft,img;corners=page===nothing ? nothing : page.corners,
                        replace_id=mode==:replace ? target : nothing,before_id=mode==:insert ? target : nothing)
                    if page !== nothing
                        trigger.state=:captured; trigger.captured=detection.thumbnail
                    end
                    lock(ui.frame_lock) do
                        ui.latest=merge(previewframe,(captured=id,state=:captured))
                    end
                    ui.last_capture[]=id
                    A.beep()
                end
                end
            end
        catch err
            lock(ui.frame_lock) do
                ui.latest=(image=nothing,outline=Point2f[],state=:error,paused=true,error=A.review_error(err),captured=0)
            end
            pause!(ui,true)
        finally
            ui.running[]=false
            close(detector)
        end
    end)
    ui.message[]="Kamera verbunden. Bild prüfen, dann Automatik starten."
end

# The sheet's outline over the preview image, closed, in its pixel units:
# a preview pixel covers `scale` frame pixels, and Makie draws pixel i on [i-1, i].
function outline(d::A.Detection)
    d.page===nothing && return Point2f[]
    corners=[Point2f((p .- 0.5f0) ./ d.scale) for p in d.page.corners]
    push!(corners,corners[1])
end

function Base.close(ui::ScannerUI)
    ui.closed && return
    ui.closed=true; ui.running[]=false; pause!(ui,true)
    ui.timer===nothing || close(ui.timer)
    # Closing the camera releases a pending frame read. The draft worker is
    # drained before returning, and the archive remains owned by the caller.
    ui.camera===nothing || close(ui.camera)
    ui.task===nothing || wait(ui.task)
    close(ui.draft)
    close(ui.previews)
    screen=GLMakie.Makie.getscreen(ui.figure.scene)
    screen===nothing || close(screen)
    nothing
end

"""
    scanner_gui(; camera=nothing, archive=nothing, dir=..., duplex=true, ocr=nothing, dewarp=false,
                select=Paperhawk.anygpu, camera_torch=false)

Return a controller; show `ui.figure`. The camera starts paused. Captures are
editable drafts until the explicit archive button. `close(ui)` releases camera,
draft and preview resources. GLMakie renders the figure in a native desktop
window. `select` names the GPU for the live view and the previews; the OCR
engine has its own.
"""
function A.scanner_gui(;camera=nothing,archive=nothing,dir=A.data_dir("scans","review_"*A.Dates.format(A.Dates.now(),"yyyymmdd_HHMMSS")),
        duplex=true,dpi=300,ocr=nothing,dewarp=false,draft=nothing,image_loader=nothing,window_size=(1600,1000),
        camera_torch=false,select=A.anygpu)
    draft===nothing && (draft=ReviewSession(dir;duplex,dpi,ocr,dewarp))
    previews=A.Previews(;select)
    image_loader===nothing && (image_loader=(path,width,area)->A.tile(previews,path,width,area))
    fig=Figure(size=window_size,backgroundcolor=BG,fontsize=15,figure_padding=16)
    selected=Observable(isempty(draft.entries) ? 0 : last(draft.entries).id)
    message=Observable("Blatt auflegen → erfassen → prüfen. Die Nummern entstehen beim Archivieren.")
    ui=ScannerUI(fig,draft,archive,A.engine(draft.processor),previews,select,selected,message,nothing,nothing,nothing,Threads.Atomic{Bool}(false),
        Threads.Atomic{Bool}(true),Channel{Any}(Inf),nothing,ReentrantLock(),ReentrantLock(),Threads.Atomic{Int}(0),Dict{Symbol,Any}(),false)
    header=GridLayout(fig[1,1:3];tellheight=false,width=Relative(1),height=Relative(1))
    Label(header[1,1],"Paperhawk",fontsize=26,font=:bold,color=INK,halign=:left)
    countlabel=Label(header[1,2],"",color=MUTED,halign=:left,tellwidth=false)
    colsize!(header,1,Fixed(170));colsize!(header,2,Auto(1))
    Box(fig[2,1];color=:white,strokewidth=0,cornerradius=10)
    Box(fig[2,2];color=CANVAS,strokewidth=0,cornerradius=10)
    Box(fig[2,3];color=:white,strokewidth=0,cornerradius=10)
    capture=GridLayout(fig[2,1];alignmode=Outside(12),tellheight=false,tellwidth=false,width=Relative(1),height=Relative(1))
    document=GridLayout(fig[2,2];alignmode=Outside(12),tellheight=false,tellwidth=false,width=Relative(1),height=Relative(1))
    inspect=GridLayout(fig[2,3];alignmode=Outside(12),tellheight=false,tellwidth=false,width=Relative(1),height=Relative(1))
    footer=GridLayout(fig[3,1:3];tellheight=false,width=Relative(1),height=Relative(1))
    shownmessage=lift(m->first(m,150)*(length(m)>150 ? " …" : ""),message)
    Label(footer[1,1:3],shownmessage,color=MUTED,halign=:left,tellwidth=false,tellheight=false,word_wrap=true,fontsize=13)
    Label(capture[1,1],"ERFASSEN",fontsize=12,font=:bold,color=MUTED,halign=:left,tellwidth=false)
    Label(capture[7,1],"AUFNAHMEN",fontsize=12,font=:bold,color=MUTED,halign=:left,tellwidth=false)
    Label(inspect[1,1:2],"SEITE PRÜFEN",fontsize=12,font=:bold,color=MUTED,halign=:left)
    function button(place,key,label,f)
        b=Button(place;label,buttoncolor=RGBf(0.94,0.96,0.97),labelcolor=INK,
            buttoncolor_hover=RGBf(0.86,0.91,0.94),buttoncolor_active=RGBf(0.77,0.86,0.91),
            strokewidth=0,cornerradius=5,fontsize=14,height=34,width=Relative(1),tellwidth=false)
        ui.buttons[key]=b
        on(b.clicks) do _
            action(f,ui)
        end
        b
    end
    button(capture[4,1],:connect,"Kamera verbinden",()->connect!(ui,PhoneCamera(;torch=camera_torch)))
    pausebutton=button(capture[5,1],:pause,"Automatik starten",()->begin
        ui.running[] || throw(ArgumentError("Zuerst Kamera verbinden"))
        ui.draft.commit_started && throw(ArgumentError("Dieser Entwurf wird bereits archiviert"))
        pause!(ui,!ui.paused[])
    end)
    pausebutton.buttoncolor[]=ACCENT;pausebutton.labelcolor[]=:white
    function capture_command(mode)
        ui.running[] || throw(ArgumentError("Keine laufende Kamera"))
        mode!=:add && selected[]==0 && throw(ArgumentError("Zuerst Aufnahme auswählen"))
        mode!=:add && (pause!(ui,true))
        put!(ui.commands,(mode,mode==:add ? nothing : selected[]))
        message[]=mode==:replace ? "Ausgewählte Seite erneut unter die Kamera legen." : "Nächsten Kameraframe erfassen …"
    end
    button(capture[6,1],:capture,"Einmal erfassen",()->capture_command(:add))
    button(inspect[3,1:2],:replace,"Seite neu aufnehmen",()->capture_command(:replace))
    button(inspect[14,2],:insert,"Davor scannen",()->capture_command(:insert))
    commitbutton=button(header[1,4],:commit,"Geprüft · Archivieren",()->begin
        archive===nothing && throw(ArgumentError("Kein Archiv verbunden; Entwurf bleibt gespeichert"))
        pause!(ui,true)
        isready(ui.commands) && throw(ArgumentError("Aufnahme wartet noch auf einen Kameraframe"))
        message[]="Archiviere geprüfte Dokumente …"
        @async action(ui) do
            # Allow an in-flight frame to finish before freezing the draft.
            paths=fetch(Threads.@spawn begin
                lock(ui.capture_lock) do
                    isready(ui.commands) && throw(ArgumentError("Aufnahme wartet noch auf einen Kameraframe"))
                    review_commit!(draft,archive)
                end
            end)
            message[]="Archiviert: "*join(basename.(paths),", ")*". Originale in dieser Reihenfolge abheften."
        end
    end)
    commitbutton.buttoncolor[]=GREEN;commitbutton.labelcolor[]=:white
    button(header[1,5],:close,"Beenden",()->begin
        @async action(ui) do
            close(ui)
            message[]="Sitzung beendet. Entwurf gespeichert unter "*draft.dir
        end
    end)
    archivehint=Label(capture[9,1],archive===nothing ? "Entwurf lokal gespeichert" : "Archiv verbunden";
        tellwidth=false,tellheight=false,word_wrap=true,halign=:left,justification=:left,fontsize=12,color=MUTED)
    live=Observable(copy(EMPTY)); result=Observable(copy(EMPTY))
    resultx=Observable((0.0,Float64(size(EMPTY,1))))
    resulty=Observable((0.0,Float64(size(EMPTY,2))))
    fullsize=Ref(size(EMPTY)); rendered_area=Ref{Any}(nothing)
    left=Axis(capture[2,1];title="Live · Blattrand prüfen",titlevisible=false,yreversed=true,aspect=DataAspect(),backgroundcolor=BG)
    right=Axis(document[2,1];title="Aufnahme · zoomen und Text prüfen",titlevisible=false,yreversed=true,aspect=DataAspect(),backgroundcolor=CANVAS)
    hidedecorations!(left); hidedecorations!(right); hidespines!(left); hidespines!(right)
    image!(left,live); image!(right,resultx,resulty,result)
    liveoutline=Observable(Point2f[])
    lines!(left,liveoutline;color=:red,linewidth=2)
    scatter!(left,map(o->isempty(o) ? Point2f[] : o[1:1],liveoutline);color=GREEN,markersize=12)
    livehint=Label(capture[3,1],"Kamera nicht verbunden",color=MUTED,tellwidth=false,tellheight=false,word_wrap=true,halign=:left,justification=:left,fontsize=13)
    detail=Label(inspect[2,1:2],"Noch keine Aufnahme",color=INK,tellwidth=false,tellheight=false,word_wrap=true,halign=:left,justification=:left,fontsize=14)
    pagetitle=Label(document[1,1],"Noch keine Aufnahme",font=:bold,color=INK,halign=:left,tellwidth=false)
    cameraempty=text!(left,0.5,0.5;text="Kein\nKamerabild",space=:relative,align=(:center,:center),color=MUTED,fontsize=13)
    # Six thumbnails keep the recent capture sequence visible at a glance.
    stripgrid=GridLayout(capture[8,1];tellwidth=false,tellheight=false,width=Relative(1),valign=:top); thumbs=Observable[]; captions=Button[]; thumbaxes=Axis[]; thumbids=zeros(Int,6)
    for i in 1:6
        img=Observable(copy(EMPTY)); push!(thumbs,img)
        ax=Axis(stripgrid[i,1];aspect=DataAspect(),yreversed=true)
        push!(thumbaxes,ax);rowsize!(stripgrid,i,Relative(1/6))
        hidedecorations!(ax); hidespines!(ax); image!(ax,img)
        b=Button(stripgrid[i,2];label="",fontsize=13,tellwidth=false,tellheight=false,width=Relative(1),height=Relative(1),padding=(4,4,4,4),
            labelcolor=INK,buttoncolor=:white,buttoncolor_hover=BG,strokewidth=0,cornerradius=5); push!(captions,b)
        on(b.clicks) do _
            pause!(ui,true)
            thumbids[i]==0 || (selected[]=thumbids[i])
        end
    end
    colsize!(stripgrid,1,Fixed(64));colsize!(stripgrid,2,Auto(1));colgap!(stripgrid,8);rowgap!(stripgrid,5)
    navigation=GridLayout(document[3,1];tellwidth=false,tellheight=false,width=Relative(1),height=Relative(1))
    button(navigation[1,1],:previous,"‹ Zurück",()->begin
        pause!(ui,true)
        ids=[e.id for e in draft.entries]; i=findfirst(==(selected[]),ids)
        i===nothing || (selected[]=ids[max(1,i-1)])
    end)
    button(navigation[1,4],:next,"Weiter ›",()->begin
        pause!(ui,true)
        ids=[e.id for e in draft.entries]; i=findfirst(==(selected[]),ids)
        i===nothing || (selected[]=ids[min(length(ids),i+1)])
    end)
    button(navigation[1,2],:fit,"Ganze Seite",()->limits!(right,0,fullsize[][1],fullsize[][2],0))
    button(navigation[1,3],:textzoom,"Text lesen",()->begin
        selected[]==0 && return
        pause!(ui,true)
        words=selected_entry(ui).words
        isempty(words) && return
        w,h=fullsize[];margin=max(w,h)*0.025
        x0=max(0,minimum(w->w.x,words)-margin);x1=min(w,maximum(w->w.x+w.width,words)+margin)
        y0=max(0,minimum(w->w.y,words)-margin);y1=min(h,maximum(w->w.y+w.height,words)+margin)
        limits!(right,x0,x1,y1,y0)
    end)
    button(inspect[4,1],:rotate,"90° drehen",()->selected_action(e->review_edit!(draft,e.id;rotation=something(e.rotation,e.detected_rotation)+90),ui))
    deletebutton=button(inspect[5,2],:delete,"Entfernen",()->selected_action(e->review_delete!(draft,e.id),ui))
    deletebutton.labelcolor[]=RED
    button(inspect[5,1],:undo,"Rückgängig",()->begin pause!(ui,true);review_undo!(draft) end)
    button(inspect[13,1],:earlier,"← Früher",()->selected_action(e->review_move!(draft,e.id,-1),ui))
    button(inspect[13,2],:later,"Später →",()->selected_action(e->review_move!(draft,e.id,1),ui))
    button(inspect[14,1],:include,"Auslassen",()->selected_action(e->review_edit!(draft,e.id;included=!e.included),ui))
    button(inspect[12,1],:split,"Neues Dokument",()->selected_action(e->review_edit!(draft,e.id;starts=true),ui))
    button(inspect[12,2],:merge,"Zusammenfügen",()->selected_action(e->review_edit!(draft,e.id;starts=false),ui))
    Label(inspect[10,1:2],"ZUORDNUNG & REIHENFOLGE",fontsize=12,font=:bold,color=MUTED,halign=:left,tellwidth=false)
    sidemenu=Menu(inspect[11,1:2];height=34,tellwidth=false,fontsize=14,options=[("Seite zuordnen",:none),("Vorderseite",:front),("Rückseite",:back),("Einseitig",:single)])
    on(sidemenu.selection) do side
        side==:none || selected_action(e->review_edit!(draft,e.id;side),ui)
    end
    cropmode=Ref(false); points=Vec2f[]; cropdots=Observable(Point2f[])
    scatter!(right,cropdots;color=:orange,markersize=14)
    uncertain=Observable(Point2f[])
    lines!(right,uncertain;color=:darkorange,linewidth=2)
    button(inspect[4,2],:crop,"Zuschneiden",()->selected_action(ui) do e
        if cropmode[]
            cropmode[]=false; empty!(points); cropdots[]=Point2f[]
            loaded[]=nothing; lastversion[]=-1
            message[]="Zuschnitt abgebrochen."
            return
        end
        cropmode[]=true; empty!(points); cropdots[]=Point2f[]; uncertain[]=Point2f[]
        ui.buttons[:crop].label[]="Zuschnitt abbrechen"
        loaded[]=nothing; lastversion[]=-1
        message[]="Zuschnitt: oben links, oben rechts, unten rechts, unten links anklicken."
    end)
    textheader=GridLayout(inspect[6,1:2];tellwidth=false,tellheight=false,width=Relative(1),height=Relative(1))
    Label(textheader[1,1],"TEXT KORRIGIEREN",fontsize=12,font=:bold,color=MUTED,halign=:left,tellwidth=false)
    retrybutton=button(textheader[1,2],:retry,"OCR erneut",()->selected_action(e->review_edit!(draft,e.id;retry=true),ui))
    retrybutton.height[]=24;retrybutton.fontsize[]=12;colsize!(textheader,2,Fixed(90))
    wordbox=Textbox(inspect[7,1:2];placeholder="Wort im Bild anklicken …",height=34,width=Relative(1),tellwidth=false,fontsize=14)
    Label(inspect[8,1:2],"Wort anklicken, hier ändern, Enter.\nOrange = unsichere Erkennung.",color=MUTED,fontsize=12,tellwidth=false,tellheight=false,word_wrap=true,halign=:left)
    wordindex=Ref(0); wordentry=Ref(0); wordrevision=Ref(0)
    on(events(right).mousebutton) do event
        if event.button==Mouse.left && event.action==Mouse.press && GLMakie.Makie.is_mouseinside(right.scene)
            action(ui) do
                selected[]==0 && return
                p=Vec2f(mouseposition(right))
                e=selected_entry(ui)
                if cropmode[]
                    loaded[]==(e.id,e.revision,e.source,true) || return
                    push!(points,p); cropdots[]=Point2f.(points)
                    if length(points)==4
                        corners=Tuple(points)
                        empty!(points);cropdots[]=Point2f[]
                        A.review_validate_corners(corners,fullsize[])
                        review_edit!(draft,e.id;corners)
                        cropmode[]=false;cropdots[]=Point2f[];empty!(points)
                        message[]="Zuschnitt übernommen; Seite wird neu verarbeitet."
                    end
                elseif e.status==:ready && loaded[]==(e.id,e.revision,e.output,true)
                    i=findfirst(w->w.x<=p[1]<=w.x+w.width && w.y<=p[2]<=w.y+w.height,e.words)
                    if i !== nothing
                        pause!(ui,true)
                        # Only shown, not stored: storing it would record an unchanged word as a correction.
                        wordindex[]=i;wordentry[]=e.id;wordrevision[]=e.revision;wordbox.editor.arg1=e.words[i].text
                    end
                end
            end
        end
        Consume(false)
    end
    on(wordbox.stored_string) do value
        value===nothing && return
        action(ui) do
            wordentry[]==selected[] && wordindex[]>0 || throw(ArgumentError("Zuerst ein OCR-Wort im Bild anklicken"))
            selected_entry(ui).revision==wordrevision[] || throw(ArgumentError("Seite wurde geändert; Wort erneut anklicken"))
            A.review_word!(draft,selected[],wordindex[],value)
            message[]="OCR-Wort korrigiert."
        end
    end
    ocrlabel=Label(inspect[9,1:2],"",tellwidth=false,tellheight=false,word_wrap=true,
        halign=:left,valign=:top,justification=:left,fontsize=13,color=MUTED)
    issueslabel=Label(document[4,1],"",tellwidth=false,tellheight=false,word_wrap=true,
        halign=:left,color=AMBER,fontsize=13)
    query=Textbox(footer[2,1];placeholder="Archiv durchsuchen …",height=32,width=Relative(1),tellwidth=false,fontsize=14)
    found=Label(footer[2,3],"Suche liefert die Nummer im Papierordner.",tellwidth=false,tellheight=false,
        word_wrap=true,halign=:left,fontsize=12,color=MUTED)
    button(footer[2,2],:search,"Suchen",()->begin
        archive===nothing && throw(ArgumentError("Kein Archiv verbunden"))
        rows=search_documents(archive,query.editor.arg1[];limit=3)
        found.text[]=isempty(rows) ? "Keine Treffer" : join(["Nr. $(r["number"]) · $(first(r["title"],45))" for r in rows],"   /   ")
    end)
    colsize!(footer,1,Fixed(260));colsize!(footer,2,Fixed(85));colsize!(footer,3,Auto(1))
    rowsize!(footer,1,Fixed(24));rowsize!(footer,2,Fixed(34));rowgap!(footer,4)
    rowsize!(fig.layout,1,Fixed(48));rowsize!(fig.layout,2,Auto(1));rowsize!(fig.layout,3,Fixed(62))
    rowgap!(fig.layout,12);colgap!(fig.layout,12)
    colsize!(fig.layout,2,Auto(1))
    function resize_strip(height)
        n=clamp(length(draft.entries),1,6)
        rowheight=clamp((height-570)/n,30,96)
        for slot in 1:6
            rowsize!(stripgrid,slot,Fixed(slot<=n ? rowheight : 0))
        end
    end
    function resize_layout(area)
        width,height=area.widths
        colsize!(fig.layout,1,Fixed(clamp(width*0.16,220,300)))
        colsize!(fig.layout,3,Fixed(clamp(width*0.19,280,350)))
        rowsize!(capture,2,Fixed(clamp(height*0.18,110,200)))
        resize_strip(height)
    end
    resize_layout(fig.scene.viewport[])
    on(resize_layout,fig.scene.viewport)
    for (row,height) in ((1,20),(3,36),(4,34),(5,34),(6,34),(7,22),(9,36))
        rowsize!(capture,row,Fixed(height))
    end
    rowsize!(capture,8,Auto(1));rowgap!(capture,6)
    colsize!(capture,1,Relative(1));colsize!(document,1,Relative(1))
    for (row,height) in ((1,26),(3,34),(4,38));rowsize!(document,row,Fixed(height));end
    rowsize!(document,2,Auto(1));rowgap!(document,8)
    for (row,height) in enumerate((20,50,34,34,34,24,34,32,74,20,34,34,34,34))
        rowsize!(inspect,row,Fixed(height))
    end
    # An explicit flexible last row keeps controls at the top on tall screens.
    Label(inspect[15,1:2],"",tellheight=false,tellwidth=false)
    rowsize!(inspect,15,Auto(1));rowgap!(inspect,6);colgap!(inspect,6)
    colsize!(inspect,1,Relative(0.5));colsize!(inspect,2,Relative(0.5))
    windowed=Ref((0,0,1600,1000))
    function toggle_fullscreen()
        screen=GLMakie.Makie.getscreen(fig.scene)
        screen===nothing && return
        glfw=GLMakie.GLFW;window=screen.glscreen
        if glfw.GetWindowMonitor(window)==glfw.Monitor(C_NULL)
            x,y=glfw.GetWindowPos(window);w,h=glfw.GetWindowSize(window)
            windowed[]=(x,y,w,h)
            monitor=glfw.GetPrimaryMonitor();mode=glfw.GetVideoMode(monitor)
            glfw.SetWindowMonitor(window,monitor,0,0,mode.width,mode.height,glfw.DONT_CARE)
            ui.buttons[:fullscreen].label[]="Fenster · F11"
        else
            glfw.SetWindowMonitor(window,glfw.Monitor(C_NULL),windowed[]...,glfw.DONT_CARE)
            ui.buttons[:fullscreen].label[]="Vollbild · F11"
        end
    end
    button(header[1,3],:fullscreen,"Vollbild · F11",toggle_fullscreen)
    for (column,width) in ((3,112),(4,195),(5,90));colsize!(header,column,Fixed(width));end
    on(events(fig).keyboardbutton) do event
        event.key==Keyboard.f11 && event.action==Keyboard.press && action(toggle_fullscreen,ui)
        Consume(false)
    end
    cache=Dict{Tuple,Any}()
    pending_images=Dict{Tuple,Task}()
    failed_images=Set{Tuple}()
    function picture(path,width=180,area=nothing)
        key=(path,width,area)
        haskey(cache,key) && return cache[key]
        if !haskey(pending_images,key) && !(key in failed_images) && length(pending_images)<2
            pending_images[key]=Threads.@spawn try
                (image_loader(path,width,area),nothing)
            catch err
                (nothing,A.review_error(err))
            end
        end
        nothing
    end
    function poll_images!()
        changed=false
        for key in collect(keys(pending_images))
            task=pending_images[key]
            istaskdone(task) || continue
            pixels,err=fetch(task);delete!(pending_images,key)
            if err===nothing
                # Keep only one decoded full-size page in this cache. The
                # displayed Observable retains its own current image.
                key[2]>180 && filter!(p->p.first[2]<=180,cache)
                cache[key]=pixels
            else
                push!(failed_images,key)
                message[]="Bild konnte nicht geladen werden: "*err
            end
            changed=true
        end
        changed
    end
    lastversion=Ref(-1); lastselected=Ref(-1); lastnext=Ref(draft.nextid)
    loaded=Ref{Any}(nothing)
    archive_refresh=Ref(0.0)
    on(right.finallimits) do _
        lastversion[]=-1
    end
    on(selected) do _
        cropmode[]=false;empty!(points);cropdots[]=Point2f[];wordindex[]=0
    end
    ui.timer=Timer(0;interval=0.05) do _
        ui.closed && return
        action(ui) do
            images_changed=poll_images!()
            frame=lock(ui.frame_lock) do
                f=ui.latest;ui.latest=nothing;f
            end
            if frame !== nothing
                if frame.image !== nothing
                    cameraempty.visible[]=false
                    if size(live[])==size(frame.image)
                        copyto!(live[],frame.image)
                        notify(live)
                    else
                        live[]=frame.image
                        autolimits!(left)
                    end
                end
                liveoutline[]=frame.outline
                if !isempty(frame.error)
                    message[]="Kamera: "*frame.error
                    livehint.text[]="Kamera unterbrochen · Entwurf bleibt erhalten";livehint.color[]=RED
                else
                    setchanged!(livehint.text,frame.state==:missing ? "Kein Blattrand erkannt" : frame.paused ? "PAUSE · Blattrand erkannt" :
                        frame.state==:captured ? "ERFASST · nächstes Blatt / Rückseite" : "Blatt ruhig halten …")
                    setchanged!(livehint.color,frame.state==:captured ? GREEN : AMBER)
                end
            end
            setchanged!(pausebutton.label,ui.paused[] ? "Automatik starten" : "Pause")
            setchanged!(ui.buttons[:crop].label,cropmode[] ? "Abbrechen" : "Zuschneiden")
            if archive!==nothing && time()-archive_refresh[]>1
                pending=A.pending_classifications(archive)
                if pending!==nothing
                    archivehint.text[]=archive.classifier===nothing ? "Archiv · Volltextsuche bereit" :
                        pending==0 ? "Archiv · Zusammenfassungen fertig" : "$pending Zusammenfassungen im Hintergrund"
                    archive_refresh[]=time()
                end
            end
            lock(draft.lock) do
                captured=Threads.atomic_xchg!(ui.last_capture,0)
                captured==0 || (selected[]=captured)
                if images_changed || lastversion[]!=draft.version || lastselected[]!=selected[]
                    ids=[e.id for e in draft.entries]
                    selected[] in ids || (selected[]=isempty(ids) ? 0 : last(ids))
                    index=findfirst(==(selected[]),ids)
                    # Queue the selected page before thumbnails. Decoding and
                    # resizing run off the event loop, with at most two loads.
                    if index !== nothing
                        e=draft.entries[index]
                        path=cropmode[] ? e.source : isfile(e.output) ? e.output : e.source
                        key=(e.id,e.revision,path,isfile(path))
                        fresh=key!=loaded[]
                        limits=right.finallimits[]
                        w,h=fullsize[]
                        area=fresh ? nothing : (clamp(floor(Int,limits.origin[1]),0,w-1),
                            clamp(floor(Int,limits.origin[2]),0,h-1),
                            clamp(ceil(Int,limits.origin[1]+limits.widths[1]),1,w),
                            clamp(ceil(Int,limits.origin[2]+limits.widths[2]),1,h))
                        area==(0,0,w,h) && (area=nothing)
                        if fresh || area!=rendered_area[]
                            tile=isfile(path) ? picture(path,1200,area) : nothing
                            if tile!==nothing
                                x0,y0,x1,y1=tile.extent
                                resultx[]=(Float64(x0),Float64(x1));resulty[]=(Float64(y0),Float64(y1))
                                result[]=tile.pixels;fullsize[]=tile.fullsize
                                loaded[]=key;rendered_area[]=area
                                # limits! derives axis direction from endpoint
                                # order; image/OCR coordinates start at the top.
                                fresh && limits!(right,0,fullsize[][1],fullsize[][2],0)
                            elseif loaded[]===nothing || loaded[][1:2]!=key[1:2] || cropmode[]
                                result[]===EMPTY || (result[]=EMPTY)
                            end
                        end
                    end
                    pending=count(e->e.status in (:queued,:processing),draft.entries)
                    n=length(ids);nd=length(review_groups(draft))
                    resize_strip(fig.scene.viewport[].widths[2])
                    setchanged!(countlabel.text,"$n $(n==1 ? "Seite" : "Seiten") · $nd $(nd==1 ? "Dokument" : "Dokumente")"*(pending>0 ? " · $pending in Arbeit" : ""))
                    start=index===nothing ? 1 : max(1,index-4)
                    for slot in 1:6
                        k=start+slot-1
                        if k<=length(ids)
                            thumbaxes[slot].scene.visible[]=true;captions[slot].blockscene.visible[]=true
                            e=draft.entries[k];thumbids[slot]=e.id
                            path=isfile(e.output) ? e.output : e.source
                            pixels=isfile(path) ? picture(path) : nothing
                            nextimage=pixels===nothing ? EMPTY : pixels.pixels
                            if thumbs[slot][]!==nextimage
                                thumbs[slot][]=nextimage
                                autolimits!(thumbaxes[slot])
                            end
                            setchanged!(captions[slot].label,"$(e.id) · $(e.side==:back ? "Rückseite" : e.side==:front ? "Vorderseite" : "Einseitig")\n$(e.status==:ready ? (e.included ? "OCR fertig" : "Ausgelassen") : e.status==:error ? "Fehler · prüfen" : "In Arbeit …")")
                            setchanged!(captions[slot].buttoncolor,e.id==selected[] ? RGBf(0.83,0.92,0.96) : e.status==:error ? :mistyrose : :white)
                        else
                            thumbaxes[slot].scene.visible[]=false;captions[slot].blockscene.visible[]=false
                            thumbids[slot]=0
                            thumbs[slot][]===EMPTY || (thumbs[slot][]=EMPTY)
                            setchanged!(captions[slot].label,"–")
                        end
                    end
                    if index !== nothing && !cropmode[]
                        e=draft.entries[index];path=isfile(e.output) ? e.output : e.source
                        # Boxes must correspond to the processed image actually
                        # displayed, never to an old/raw image still loading.
                        weak=e.status==:ready && loaded[]==(e.id,e.revision,e.output,true) ? filter(w->w.confidence<80,e.words) : Word[]
                        boxes=Point2f[]
                        for w in weak
                            append!(boxes,[Point2f(w.x,w.y),Point2f(w.x+w.width,w.y),
                                Point2f(w.x+w.width,w.y+w.height),Point2f(w.x,w.y+w.height),
                                Point2f(w.x,w.y),Point2f(NaN,NaN)])
                        end
                        setchanged!(uncertain,boxes)
                        state=e.status==:ready ? (e.blank ? "Leer erkannt · bitte prüfen" :
                            isempty(e.words) ? "Kein Text erkannt · bitte prüfen" :
                            isempty(weak) ? "OCR fertig · Sichtprüfung nötig" : "$(length(weak)) unsichere Wörter · orange markiert") : e.status==:error ? e.error : "Verarbeitung läuft …"
                        if e.corners===nothing && e.status==:ready
                            state="Blattrand fehlt · Zuschneiden nötig"
                        end
                        sidename=e.side==:front ? "Vorderseite" : e.side==:back ? "Rückseite" : "einseitig"
                        setchanged!(pagetitle.text,"Seite $(e.id) · $sidename")
                        setchanged!(detail.text,state*"\n"*(e.included ? "Wird ins PDF übernommen" : "Aus dem PDF ausgelassen"))
                        setchanged!(ui.buttons[:include].label,e.included ? "Auslassen" : "Ins PDF")
                        setchanged!(detail.color,e.status==:error ? RED : e.corners===nothing || e.blank || isempty(e.words) || !isempty(weak) ? AMBER : INK)
                        text=A.text(e.words)
                        setchanged!(ocrlabel.text,first(text,120)*(length(text)>120 ? " …" : ""))
                    elseif index === nothing
                        result[]=copy(EMPTY); uncertain[]=Point2f[]; loaded[]=nothing
                        detail.text[]="Noch keine Aufnahme"; ocrlabel.text[]=""
                        pagetitle.text[]="Noch keine Aufnahme"
                    end
                    issues=review_issues(draft)
                    setchanged!(issueslabel.text,isempty(issues) ? "Sichtprüfung: vollständig, scharf, richtig zugeordnet?" : join(first(issues,2)," · "))
                    lastversion[]=draft.version;lastselected[]=selected[]
                    length(cache)>60 && empty!(cache)
                end
            end
        end
    end
    on(events(fig).window_open) do opened
        opened || close(ui)
    end
    camera===nothing || connect!(ui,camera)
    return ui
end

"""
    scanner(; select = anygpu, camera_torch = true, duplex = true, classify = false,
            dir = <new draft>, archive = data_dir("archiv"))

Open the scanner in a maximised window and return when it is closed. The OCR
engine, the archive in `archive` and, with `classify`, the local LLM that
summarises its documents run on the GPU `select` names (see `Mantle.Device`),
as do the live view and the previews. `dir` reopens an existing draft.
"""
function A.scanner(; select = A.anygpu, camera_torch::Bool = true, duplex::Bool = true, classify::Bool = false,
        dir = nothing, archive::AbstractString = A.data_dir("archiv"))
    ocr = PaddleOCR(; select)
    classifier = documents = ui = nothing
    try
        classify && (classifier = BonsaiClassifier(ocr))
        documents = DocumentArchive(archive; classifier)
        options = dir === nothing ? (;) : (; dir)
        ui = A.scanner_gui(; archive = documents, ocr, duplex, camera_torch, select, options...)
        screen = display(GLMakie.Screen(; title = "Paperhawk"), ui.figure)
        GLMakie.GLFW.MaximizeWindow(screen.glscreen)
        wait(screen)
    finally
        # The classifier shares the OCR engine's device: it goes first.
        ui === nothing || close(ui)
        documents === nothing || close(documents)
        classifier === nothing || close(classifier)
        close(ocr)
    end
    return nothing
end
end
