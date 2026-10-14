# Apply before importing GLMakie/Mantle. This workstation's scanner is pinned
# to its RTX 4000 Ada; missing hardware must fail rather than select another GPU.
function scanner_ada_environment!()
    rows=split(strip(read(`nvidia-smi --query-gpu=name,uuid --format=csv,noheader`,String)),'\n')
    matches=filter(row->startswith(strip(first(split(row,','))),"NVIDIA RTX 4000 Ada Generation"),rows)
    length(matches)==1 || error("Scanner requires exactly one NVIDIA RTX 4000 Ada Generation")
    driver="/usr/share/vulkan/icd.d/nvidia_icd.x86_64.json"
    isfile(driver) || error("NVIDIA Vulkan driver not found: $driver")
    ENV["VK_DRIVER_FILES"]=driver
    ENV["VK_ICD_FILENAMES"]=driver
    ENV["CUDA_VISIBLE_DEVICES"]=strip(last(split(only(matches),',')))
    ENV["__NV_PRIME_RENDER_OFFLOAD"]="1"
    ENV["__GLX_VENDOR_LIBRARY_NAME"]="nvidia"
    ENV["__VK_LAYER_NV_optimus"]="NVIDIA_only"
    nothing
end

function scanner_check_ada!()
    devices=Paperhawk.Mantle.devices()
    length(devices)==1 && only(devices).name=="NVIDIA RTX 4000 Ada Generation" ||
        error("Scanner requires RTX 4000 Ada exclusively; visible devices: $devices")
    nothing
end

scanner_ada_environment!()
