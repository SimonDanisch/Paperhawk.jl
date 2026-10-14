# libpng's simplified API accepts the scanner's contiguous x-first pixels
# directly. PNGFiles.save/load otherwise transpose full pages in both directions.
# The simplified API also returns errors normally (it handles libpng longjmp).
const DRAFT_LIBPNG=PNGFiles.libpng
function draft_png_header()
    Ref(PNGFiles.png_image(C_NULL,UInt32(PNGFiles.PNG_IMAGE_VERSION),
        UInt32(0),UInt32(0),UInt32(0),UInt32(0),UInt32(0),UInt32(0),ntuple(_->Cchar(0),64)))
end
function draft_png_error(header)
    bytes=reinterpret(UInt8,collect(header[].message))
    stop=findfirst(iszero,bytes)
    error("Draft PNG: ",String(bytes[1:(stop===nothing ? length(bytes) : stop-1)]))
end
function draft_png_path(path)
    file=String(path)
    occursin('\0',file) && throw(ArgumentError("PNG path contains a null character"))
    file
end

function review_save_image(path,img::Matrix{T}) where {T<:Union{RGB{N0f8},Gray{N0f8}}}
    file=draft_png_path(path)
    isempty(img) && throw(ArgumentError("Cannot save an empty PNG"))
    header=draft_png_header()
    GC.@preserve header img begin
        ptr=Base.unsafe_convert(PNGFiles.png_imagep,header)
        ptr.width=UInt32(size(img,1));ptr.height=UInt32(size(img,2))
        ptr.format=UInt32(T==RGB{N0f8} ? PNGFiles.PNG_FORMAT_RGB : PNGFiles.PNG_FORMAT_GRAY)
        ptr.flags=UInt32(PNGFiles.PNG_IMAGE_FLAG_FAST)
        try
            # No Julia callbacks: native compression may run while another
            # thread collects garbage, instead of delaying every Julia thread.
            ok=@ccall gc_safe=true DRAFT_LIBPNG.png_image_write_to_file(
                ptr::PNGFiles.png_imagep,file::Cstring,0::Cint,
                pointer(img)::Ptr{Cvoid},0::Int32,C_NULL::Ptr{Cvoid})::Cint
            ok==1 || draft_png_error(header)
        finally
            PNGFiles.png_image_free(ptr)
        end
    end
    nothing
end
# Less common CPU modes retain PNGFiles' conversion support.
review_save_image(path,img)=PNGFiles.save(path,permutedims(img);filters=Int(PNGFiles.PNG_FILTER_SUB))

function review_load_image(path;buffer=nothing)
    file=draft_png_path(path)
    header=draft_png_header()
    GC.@preserve header begin
        ptr=Base.unsafe_convert(PNGFiles.png_imagep,header)
        try
            ok=@ccall gc_safe=true DRAFT_LIBPNG.png_image_begin_read_from_file(
                ptr::PNGFiles.png_imagep,file::Cstring)::Cint
            ok==1 || draft_png_error(header)
            ptr.format=UInt32(PNGFiles.PNG_FORMAT_RGB)
            dims=(Int(header[].width),Int(header[].height))
            img=buffer isa Matrix{RGB{N0f8}} && size(buffer)==dims ? buffer : Matrix{RGB{N0f8}}(undef,dims)
            GC.@preserve img begin
                ok=@ccall gc_safe=true DRAFT_LIBPNG.png_image_finish_read(
                    ptr::PNGFiles.png_imagep,C_NULL::Ptr{Cvoid},pointer(img)::Ptr{Cvoid},
                    0::Int32,C_NULL::Ptr{Cvoid})::Cint
                ok==1 || draft_png_error(header)
            end
            return img
        finally
            PNGFiles.png_image_free(ptr)
        end
    end
end
