
# Run with GLMakie loaded. Exercise the real GUI timer and Next button while
# full-resolution pages are prepared; submissions use the camera's thread pool.
function benchmark_ui(img,ocr;pages=6,classifier=nothing,text="",warmup=true,warmup_pages=6,
                      automatic=false)
    A=Paperhawk
    mktempdir() do dir
        draft=A.ReviewSession(dir;duplex=false,ocr)
        ui=A.scanner_gui(;draft)
        display(GLMakie.Screen(;title="Paperhawk · GPU-Test"),ui.figure)
        gaps=Float64[];latencies=Float64[]
        events=Channel{UInt64}(Inf)
        running=Threads.Atomic{Bool}(true)
        # The live view shows the frame shrunk on the GPU; any small x-first image will do here.
        livepic=img[1:6:end,1:6:end]
        receiver=@async for sent in events
            # Navigation intentionally pauses automatic capture. In automatic
            # mode measure main-thread dispatch without changing that state.
            automatic || (ui.buttons[:next].clicks[]+=1)
            push!(latencies,(time_ns()-sent)/1e9)
        end
        timer=nothing;sender=nothing;llm=nothing
        try
            if warmup
                for _ in 1:warmup_pages
                    lock(ui.frame_lock) do
                        ui.latest=(image=livepic,outline=GLMakie.Point2f[],state=:captured,paused=true,error="",captured=0)
                    end
                    fetch(Threads.@spawn A.review_add!(draft,img))
                    A.review_wait(draft);sleep(0.2)
                end
                sleep(0.5)
                ui.buttons[:next].clicks[]+=1
            end
            empty!(latencies)
            GC.gc() # discard construction/warm-up garbage before measurement
            lasttick=Ref(time_ns())
            timer=Timer(0;interval=0.01) do _
                now=time_ns();push!(gaps,(now-lasttick[])/1e9);lasttick[]=now
            end
            sender=Threads.@spawn while running[]
                lock(ui.frame_lock) do
                    ui.latest=(image=livepic,outline=GLMakie.Point2f[],state=:captured,paused=ui.paused[],error="",captured=0)
                end
                put!(events,time_ns());sleep(0.025)
            end
            if classifier!==nothing
                llm=@async begin
                    started=time_ns()
                    result=classifier(text,A.DEFAULT_CATEGORIES)
                    (;elapsed=(time_ns()-started)/1e9,metadata=result.metadata)
                end
                sleep(0.2)
            end
            automatic && Base.get_extension(A,:PaperhawkMakieExt).pause!(ui,false)
            classification_pending_at_scan_start=llm!==nothing && !istaskdone(llm)
            gc_before=Base.gc_num()
            elapsed=@elapsed begin
                for _ in 1:pages
                    fetch(Threads.@spawn A.review_add!(draft,img))
                    sleep(0.1)
                end
                A.review_wait(draft)
                sleep(0.3)
            end
            gc_after=Base.gc_num()
            scan_event_gap=maximum(gaps)
            scan_button_latency=maximum(latencies)
            scan_button_events=length(latencies)
            classification_pending_at_scan_end=llm!==nothing && !istaskdone(llm)
            automatic && @assert !ui.paused[] && A.SCAN_ACTIVE[]>0
            automatic && Base.get_extension(A,:PaperhawkMakieExt).pause!(ui,true)
            classification=llm===nothing ? nothing : fetch(llm)
            all(e->e.status==:ready,draft.entries) || error(join(A.review_issues(draft),"\n"))
            occursin("Bild konnte nicht geladen werden",ui.message[]) && error(ui.message[])
            startswith(ui.message[],"Fehler:") && error(ui.message[])
            return (;pages,automatic,elapsed,max_event_gap=scan_event_gap,
                max_button_latency=automatic ? nothing : scan_button_latency,
                button_events=automatic ? 0 : scan_button_events,
                max_dispatch_latency=scan_button_latency,dispatch_events=scan_button_events,
                full_run_event_gap=maximum(gaps),
                full_run_button_latency=automatic ? nothing : maximum(latencies),
                classification,classification_pending_at_scan_start,classification_pending_at_scan_end,
                gc_seconds=(gc_after.total_time-gc_before.total_time)/1e9,
                gc_collections=gc_after.pause-gc_before.pause,
                gc_safepoint_seconds=(gc_after.total_time_to_safepoint-gc_before.total_time_to_safepoint)/1e9,
                errors=filter(e->e.status==:error,draft.entries),message=ui.message[])
        finally
            running[]=false
            sender===nothing || wait(sender)
            close(events);wait(receiver)
            timer===nothing || close(timer)
            automatic && Base.get_extension(A,:PaperhawkMakieExt).pause!(ui,true)
            llm===nothing || wait(llm)
            close(ui)
            empty!(ui.figure)
        end
    end
end

# Compare bounded page preparation using one already warmed OCR engine.
# Keep model loading, JIT warm-up and optional LLM warm-up outside this timing.
function benchmark_review(img,ocr; pages=6,workers=2)
    pages>0 || throw(ArgumentError("pages must be positive"))
    A=Paperhawk
    dir=mktempdir()
    s=A.ReviewSession(dir;duplex=false,ocr,workers)
    capture_seconds=Float64[]
    try
        elapsed=@elapsed begin
            for _ in 1:pages
                push!(capture_seconds,@elapsed A.review_add!(s,img))
            end
            A.review_wait(s)
        end
        all(e->e.status==:ready,s.entries) || error(join(A.review_issues(s),"\n"))
        return (;pages,workers,elapsed,seconds_per_page=elapsed/pages,capture_seconds)
    finally
        close(s)
        rm(dir;recursive=true)
    end
end

# Observe the files the GUI uses, independently of the throughput benchmark.
# This measures availability on the Julia side, not browser rendering latency.
function benchmark_feedback(img,ocr;workers=2,interval=0.01)
    A=Paperhawk
    mktempdir() do dir
        s=A.ReviewSession(dir;duplex=false,ocr,workers)
        raw=Ref(NaN);processed=Ref(NaN);ready=Ref(NaN)
        ticks=Float64[]
        t=time_ns()
        timer=Timer(0;interval) do _
            now=(time_ns()-t)/1e9
            push!(ticks,now)
            lock(s.lock) do
                isempty(s.entries) && return
                e=only(s.entries)
                isnan(raw[]) && isfile(e.source) && (raw[]=now)
                isnan(processed[]) && isfile(e.output) && (processed[]=now)
                isnan(ready[]) && e.status==:ready && (ready[]=now)
            end
        end
        try
            capture=@elapsed A.review_add!(s,img)
            A.review_wait(s)
            only(s.entries).status==:ready || error(join(A.review_issues(s),"\n"))
            timedwait(()->!isnan(ready[]),5)==:ok || error("feedback observer timed out")
            return (capture_seconds=capture,raw_available=raw[],processed_available=processed[],
                ocr_ready=ready[],max_event_gap=maximum(diff([0.0;ticks])),poll_interval=interval)
        finally
            close(timer)
            close(s)
        end
    end
end

# Start a real classification before submitting the scan burst. Both models
# must already be warm; the metadata is fetched to verify successful completion.
function benchmark_background(img,ocr,classifier,text;pages=6,workers=2)
    A=Paperhawk
    t=time_ns()
    task=@async begin
        result=classifier(text,A.DEFAULT_CATEGORIES)
        (;elapsed=(time_ns()-t)/1e9,metadata=result.metadata)
    end
    try
        sleep(0.2)
        scan=benchmark_review(img,ocr;pages,workers)
        return (;scan,classification=fetch(task))
    finally
        wait(task)
    end
end
