# Threads that own a GPU device. Mantle submits from the thread that created a
# device, so its owner is a sticky task; two owners on one thread would wait
# for each other's work, and the live view would stall behind OCR.
const GPU_OWNERS = Dict{Int, String}()
const GPU_OWNERS_LOCK = ReentrantLock()

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
                claimed = lock(GPU_OWNERS_LOCK) do
                    haskey(GPU_OWNERS, Threads.threadid()) && return false
                    GPU_OWNERS[Threads.threadid()] = String(name)
                    true
                end
                if claimed
                    current_task().sticky = true
                    try
                        (true, f())
                    finally
                        lock(() -> delete!(GPU_OWNERS, Threads.threadid()), GPU_OWNERS_LOCK)
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

"""Load UVDoc on the scanner's background process. Reuse across pages."""
function uvdoc(;backend=nothing,kw...)
    backend===nothing || return UVDocRunner.uvdoc(;backend,kw...)
    process_model(:dewarper,(;kw...))
end

unwarp(model,img)=UVDocRunner.unwarp(model,img)

struct ProcessUVDoc
    pid::Int
    id::Int
end
