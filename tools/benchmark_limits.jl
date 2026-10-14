# Kernel-enforced address-space cap for this benchmark and inherited children.
# Unlike --heap-size-hint or systemd properties without an enabled controller,
# RLIMIT_AS is enforced here. GPU initialization must fail rather than lift it.
function benchmark_memory_limit(;bytes=12*1024^3, data_bytes=6*1024^3)
    Sys.islinux() || error("This benchmark guard requires Linux")
    run(`prlimit --pid $(getpid()) --as=$bytes:$bytes --data=$data_bytes:$data_bytes`)
    limits=read("/proc/self/limits",String)
    line=only(filter(l->startswith(l,"Max address space"),split(limits,'\n')))
    fields=split(line)
    parse(Int,fields[4])==bytes && parse(Int,fields[5])==bytes || error("Address-space cap was not installed")
    dataline=only(filter(l->startswith(l,"Max data size"),split(limits,'\n')))
    datafields=split(dataline)
    parse(Int,datafields[4])==data_bytes && parse(Int,datafields[5])==data_bytes || error("Data allocation cap was not installed")
    println("Verified data allocation limit: ",data_bytes÷1024^2," MiB")
    println("Verified address-space limit: ",bytes÷1024^2," MiB (hard and soft)")
    nothing
end

# The persistent Julia tool cannot supply environment variables before launch.
# On glibc this is equivalent to the allocator settings in bounded-julia. Call
# before importing scanner/GUI packages, not after a memory-heavy warm-up.
function benchmark_native_allocator()
    Sys.islinux() || error("This allocator guard requires Linux/glibc")
    ccall(:mallopt,Cint,(Cint,Cint),-8,2)==1 || error("Could not bound malloc arenas")
    ccall(:mallopt,Cint,(Cint,Cint),-3,131072)==1 || error("Could not set mmap threshold")
    println("Native allocator: at most 2 arenas, mmap threshold 128 KiB")
    nothing
end
