# Optional separate-process engines. Normal capture/OCR uses a dedicated thread;
# these handles remain available explicitly and for the existing Bonsai API.
const PROCESS_LOCK=ReentrantLock()
const PROCESS_PID=Ref(0)
const PROCESS_MODELS=Dict{Int,Any}()
const PROCESS_NEXT_ID=Ref(0)
const PREVIEW_CACHE=Dict{String,Any}()
const PREVIEW_ORDER=String[]
const PREVIEW_LOCK=ReentrantLock()

function remember_preview(path,img)
    filter!(!=(path),PREVIEW_ORDER)
    push!(PREVIEW_ORDER,path)
    PREVIEW_CACHE[path]=img
    while length(PREVIEW_ORDER)>4
        delete!(PREVIEW_CACHE,popfirst!(PREVIEW_ORDER))
    end
    img
end
# Processed-page inputs own their pixels; only viewport rendering borrows the
# preview cache, under its lock until the independent small tile is complete.
preview_pixels(path)=review_load_image(path)
function with_preview_pixels(f,path)
    lock(PREVIEW_LOCK) do
        img=get(PREVIEW_CACHE,path,nothing)
        if img===nothing
            buffer=length(PREVIEW_ORDER)>=4 ? pop!(PREVIEW_CACHE,popfirst!(PREVIEW_ORDER)) : nothing
            img=review_load_image(path;buffer)
        end
        remember_preview(path,img)
        f(img)
    end
end

function processing_pid()
    lock(PROCESS_LOCK) do
        pid=PROCESS_PID[]
        pid!=0 && pid in Distributed.workers() && return pid
        project=dirname(Base.active_project())
        flags=`--project=$project --threads=$(clamp(Threads.nthreads(:default),2,4)),1 --gcthreads=2,1 --startup-file=no --compiled-modules=existing`
        pid=only(Distributed.addprocs(1;exeflags=flags))
        try
            Distributed.remotecall_fetch(Core.eval,pid,Main,:(using Paperhawk))
            Distributed.remotecall_fetch(Core.eval,pid,Main,:(Paperhawk.LinearAlgebra.BLAS.set_num_threads(1)))
            Distributed.remotecall_fetch(worker_scan_activity,pid,SCAN_ACTIVE[])
        catch
            Distributed.rmprocs(pid)
            rethrow()
        end
        PROCESS_PID[]=pid
        return pid
    end
end

function worker_create_model(kind,options)
    model=if kind==:ocr
        PaddleOCR(;backend=Mantle.defaultbackend(),options...)
    elseif kind==:classifier
        BonsaiClassifier(;device=Mantle.Device(),options...)
    else
        UVDocRunner.uvdoc(;backend=Mantle.defaultbackend(),options...)
    end
    PROCESS_NEXT_ID[]+=1
    id=PROCESS_NEXT_ID[]
    PROCESS_MODELS[id]=model
    id
end

function process_model(kind,options)
    pid=processing_pid()
    id=Distributed.remotecall_fetch(worker_create_model,pid,kind,options)
    kind==:ocr ? ProcessOCR(pid,id) : kind==:classifier ? ProcessClassifier(pid,id) : ProcessUVDoc(pid,id)
end

worker_scan_activity(delta)=(Threads.atomic_add!(SCAN_ACTIVE,delta);nothing)
worker_ocr_activity(delta)=(Threads.atomic_add!(OCR_PENDING,delta);nothing)
function process_ocr_activity(pid,delta)
    pid==0 || !(pid in Distributed.workers()) || Distributed.remote_do(worker_ocr_activity,pid,delta)
    nothing
end
function process_scan_activity(delta)
    pid=PROCESS_PID[]
    pid==0 || !(pid in Distributed.workers()) || Distributed.remote_do(worker_scan_activity,pid,delta)
    nothing
end

function worker_ongpu(id,f)
    try
        (ongpu(f,PROCESS_MODELS[id]),nothing)
    catch err
        (nothing,err)
    end
end
function ongpu(f,e::ProcessOCR)
    Threads.atomic_add!(OCR_PENDING,1)
    try
        result,err=Distributed.remotecall_fetch(worker_ongpu,e.pid,e.id,f)
        err===nothing || throw(err)
        result
    finally
        Threads.atomic_sub!(OCR_PENDING,1)
    end
end
worker_read_words(id,img,dpi)=read_words(PROCESS_MODELS[id],img;dpi)
worker_orientation(id,img,dpi)=orientation(PROCESS_MODELS[id],img;dpi)
read_words(e::ProcessOCR,img::AbstractMatrix;dpi=300)=Distributed.remotecall_fetch(worker_read_words,e.pid,e.id,img,dpi)
orientation(e::ProcessOCR,img::AbstractMatrix;dpi=300)=Distributed.remotecall_fetch(worker_orientation,e.pid,e.id,img,dpi)
worker_classify(id,text,categories)=PROCESS_MODELS[id](text,categories)
(c::ProcessClassifier)(text,categories)=Distributed.remotecall_fetch(worker_classify,c.pid,c.id,text,categories)
worker_unwarp(id,img)=unwarp(PROCESS_MODELS[id],img)
unwarp(m::ProcessUVDoc,img)=Distributed.remotecall_fetch(worker_unwarp,m.pid,m.id,img)

function worker_prepare_page(id,img,dewarper_id,options)
    prepare_page_image(img;ocr=PROCESS_MODELS[id],
        dewarper=dewarper_id===nothing ? nothing : PROCESS_MODELS[dewarper_id],options...)
end
function process_prepare_page(ocr::ProcessOCR,img;dewarper=nothing,options...)
    dewarper===nothing || (dewarper isa ProcessUVDoc && dewarper.pid==ocr.pid) ||
        throw(ArgumentError("OCR and UVDoc must belong to the same processing process"))
    Distributed.remotecall_fetch(worker_prepare_page,ocr.pid,ocr.id,img,
        dewarper===nothing ? nothing : dewarper.id,(;options...))
end

# Decode and cache full-resolution pages on background threads, delivering
# only viewport tiles to Makie. Also callable through the optional process.
function worker_preview(path,width,area)
    fetch(Threads.@spawn begin
      with_preview_pixels(path) do img
        w,h=size(img)
        x0,y0,x1,y1=area===nothing ? (0,0,w,h) : area
        x0=clamp(x0,0,w-1);y0=clamp(y0,0,h-1)
        x1=clamp(x1,x0+1,w);y1=clamp(y1,y0+1,h)
        scale=max(1,cld(x1-x0,width),cld(y1-y0,2width))
        (pixels=render_preview(path,img,(x0,y0,x1,y1),scale),extent=(x0,y0,x1,y1),fullsize=(w,h))
      end
    end)
end
function process_preview(path,width,area=nothing)
    pid=processing_pid()
    Distributed.remotecall_fetch(worker_preview,pid,path,width,area)
end

function worker_save_capture(path,img)
    fetch(Threads.@spawn begin
        tmp=path*".tmp.png"
        review_save_image(tmp,img)
        mv(tmp,path;force=true)
        lock(PREVIEW_LOCK) do
            remember_preview(path,img)
        end
    end)
    nothing
end

function worker_close_model(id)
    model=pop!(PROCESS_MODELS,id,nothing)
    model===nothing && return
    close(model)
    nothing
end
Base.close(m::Union{ProcessOCR,ProcessClassifier,ProcessUVDoc})=Distributed.remotecall_fetch(worker_close_model,m.pid,m.id)

function worker_review(source,corners,rotation,output,ocr_id,dpi,dewarper_id)
    Threads.atomic_add!(OCR_PENDING,1)
    try
        input=source isa AbstractString ? fetch(Threads.@spawn preview_pixels(source)) : source
        review_prepare(input,corners,rotation,output;ocr=PROCESS_MODELS[ocr_id],dpi,
            dewarper=dewarper_id===nothing ? nothing : PROCESS_MODELS[dewarper_id])
    finally
        Threads.atomic_sub!(OCR_PENDING,1)
    end
end

function process_review(source,corners,rotation,output;ocr::ProcessOCR,dpi,dewarper,image_saved)
    dewarper===nothing || (dewarper isa ProcessUVDoc && dewarper.pid==ocr.pid) ||
        throw(ArgumentError("OCR and UVDoc must belong to the same processing process"))
    job=Distributed.remotecall(worker_review,ocr.pid,source,corners,rotation,output,ocr.id,dpi,
        dewarper===nothing ? nothing : dewarper.id)
    # Publish image availability before recognition ends. No image payload is
    # serialized back to the UI; only word boxes and status cross the boundary.
    while !isready(job)
        if isfile(output)
            image_saved()
            break
        end
        sleep(0.01)
    end
    result=fetch(job)
    image_saved()
    result
end

"""Drain model work and stop the shared process after closing drafts and archives."""
function close_processing!()
    close_previews!()
    lock(PROCESS_LOCK) do
        pid=PROCESS_PID[]
        if pid!=0 && pid in Distributed.workers()
            Distributed.remotecall_fetch(pid) do
                for id in collect(keys(PROCESS_MODELS))
                    worker_close_model(id)
                end
                nothing
            end
            Distributed.rmprocs(pid)
        end
        PROCESS_PID[]=0
    end
    nothing
end
