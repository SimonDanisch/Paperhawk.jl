# Threads that own a GPU device. Mantle submits from the thread that created a
# device, so its owner is a sticky task; two owners on one thread would wait
# for each other's work, and the live view would stall behind OCR.

"""
    GPUThreads

Which threads hold a GPU owner, by name. One per process: it is the threads
that are shared, not anything a scanner owns.
"""
struct GPUThreads
    owners::Dict{Int, String}
    lock::ReentrantLock
end

const GPU_THREADS = GPUThreads(Dict{Int, String}(), ReentrantLock())

"""
    anygpu(info) -> true

The device selector that admits every device; `Mantle.Device` then takes the
best GPU. Pass a name instead, as `"RTX 4000"`, to choose one.
"""
anygpu(_) = true

"""
    spawn_gpu_owner(f, name) -> Task

`f()` in a task that stays on a thread no other GPU owner holds. Create its
devices inside `f`.
"""
function spawn_gpu_owner(f, name::AbstractString)
    Threads.@spawn :default begin
        # A new task starts on a thread that is free right now. One that lands
        # on another owner's thread ends at once and the next one tries again;
        # waiting there instead would queue it behind that owner's work.
        while true
            attempt = Threads.@spawn :default begin
                claimed = lock(GPU_THREADS.lock) do
                    haskey(GPU_THREADS.owners, Threads.threadid()) && return false
                    GPU_THREADS.owners[Threads.threadid()] = String(name)
                    true
                end
                if claimed
                    current_task().sticky = true
                    try
                        (true, f())
                    finally
                        lock(() -> delete!(GPU_THREADS.owners, Threads.threadid()), GPU_THREADS.lock)
                    end
                else
                    (false, nothing)
                end
            end
            ran, value = fetch(attempt)
            ran && return value
            yield()
        end
    end
end

"""
    GPUWorker(setup, name)
    GPUWorker(setup, parent::GPUWorker, name)

A task that owns GPU state and runs requests on it one at a time. `setup()`
makes the state on the task's thread, and [`ongpu`](@ref) runs a function on
it there. Closing the worker closes the state, on that thread.

The first form takes a thread of its own. The second shares `parent`'s thread
and device, `setup(parent_state)`, with a task of its own: its requests do not
queue behind the parent's, and the two take turns at every `yield`.
"""
struct GPUWorker
    name::String
    requests::Channel{Any}
    task::Task
end

function GPUWorker(setup, name::AbstractString)
    requests, ready = Channel{Any}(Inf), Channel{Any}(1)
    task = spawn_gpu_owner(() -> serve(setup, requests, ready), name)
    return started(GPUWorker(String(name), requests, errormonitor(task)), ready)
end

function GPUWorker(setup, parent::GPUWorker, name::AbstractString)
    requests, ready = Channel{Any}(Inf), Channel{Any}(1)
    # `@async` keeps the new task on the parent's thread, which owns the device.
    task = ongpu(state -> @async(serve(() -> setup(state), requests, ready)), parent)
    return started(GPUWorker(String(name), requests, errormonitor(task)), ready)
end

function started(w::GPUWorker, ready::Channel{Any})
    err = take!(ready)
    err === nothing || throw(err)
    return w
end

# A failed request hands its error to the caller, who rethrows it. Out of
# memory is passed as is: symbolising its backtrace can itself run out.
captured(err) = err isa OutOfMemoryError ? err : CapturedException(err, catch_backtrace())

function serve(setup, requests::Channel{Any}, ready::Channel{Any})
    state = try
        setup()
    catch err
        put!(ready, captured(err))
        return
    end
    put!(ready, nothing)
    try
        for (f, reply) in requests
            # Requests come from code loaded after this loop started (GUI
            # callbacks, Revise): run them in the newest world.
            put!(reply, try
                (Base.invokelatest(f, state), nothing)
            catch err
                (nothing, captured(err))
            end)
        end
    finally
        close(state)
    end
end

"""
    ongpu(f, worker) -> f(state)

`f(state)` on the worker's thread, after the requests before it.
"""
function ongpu(f, w::GPUWorker)
    reply = Channel{Any}(1)
    put!(w.requests, (f, reply))
    result, err = take!(reply)
    err === nothing || throw(err)
    return result
end

"""Finish the queued requests, then close the state on its thread."""
function Base.close(w::GPUWorker)
    close(w.requests)
    wait(w.task)
    return nothing
end

Base.show(io::IO, w::GPUWorker) = print(io, "GPUWorker(", repr(w.name), isopen(w.requests) ? "" : ", closed", ")")
