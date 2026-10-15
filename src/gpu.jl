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

"""
    DeviceArrays(device)

Named device arrays on one Mantle device and the plans recorded over them,
made on first use and freed by `empty!`. A graph tells the memory its passes
touch apart by the array object: two views of one buffer would be two
resources with no barrier between them. So every pass names an array by the
one object [`array!`](@ref) keeps.
"""
struct DeviceArrays{D}
    device::D
    buffers::Dict{Any, Any}
    arrays::Dict{Any, Any}
    plans::Dict{Any, Any}
end

DeviceArrays(device) = DeviceArrays(device, Dict{Any, Any}(), Dict{Any, Any}(), Dict{Any, Any}())

"""
    array!(arrays, name, T, dims) -> device array

The array `name`, made on first use and the same object while its shape stays. Its
memory is one buffer per name, so `dims` may change between calls as long as
the number of elements does not: a page and its turned self share one buffer.
A graph names one shape of it.
"""
function array!(a::DeviceArrays, name, ::Type{T}, dims::Dims) where {T}
    x = get(a.arrays, name, nothing)
    x !== nothing && eltype(x) == T && size(x) == dims && return x
    b = get!(() -> Mantle.Buffer(a.device, T, (prod(dims),)), a.buffers, name)
    eltype(b) == T && length(b) == prod(dims) ||
        throw(DimensionMismatch("array $(repr(name)) holds $(length(b)) $(eltype(b)), not $dims of $T"))
    return a.arrays[name] = reshape(Mantle.storage(b), dims)
end

"""The array `name` as [`array!`](@ref) made it last."""
Base.getindex(a::DeviceArrays, name) = a.arrays[name]

"""
    plan!(declare, arrays, key) -> Mantle.Plan

The graph `declare(graph)` builds, recorded the first time under `key`.
"""
plan!(declare, a::DeviceArrays, key) = get!(a.plans, key) do
    g = Mantle.Graph(a.device)
    declare(g)
    Mantle.record!(Mantle.Plan(g))
end

"""
    run!(declare, arrays, key)

The plan [`plan!`](@ref) records under `key`, run.
"""
run!(declare, a::DeviceArrays, key) = (Mantle.run!(plan!(declare, a, key)); nothing)

"""Wait for the device, then free every plan and array."""
function Base.empty!(a::DeviceArrays)
    Mantle.waitidle(a.device)
    foreach(Mantle.free!, values(a.plans)); empty!(a.plans)
    empty!(a.arrays)
    foreach(Mantle.free!, values(a.buffers)); empty!(a.buffers)
    return a
end
