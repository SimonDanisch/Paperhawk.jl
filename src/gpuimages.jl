# GPU page preparation: warp, lighting correction, orientation, OCR.
const GM = Mantle
const GD = PPOCRRunner.DNNKernels

@kernel function page_copy!(out, @Const(src))
    i=@index(Global)
    @inbounds out[i]=RGB{Float32}(src[i])
end
@kernel function page_peaks!(peaks,@Const(img),w::Int,h::Int,bw::Int)
    i=@index(Global)
    bx=mod(i-1,bw)+1;by=(i-1)÷bw+1
    best=0f0
    for y in ((by-1)*24+2):min(by*24,h-1),x in ((bx-1)*24+2):min(bx*24,w-1)
        @inbounds v=(luminance(img[x-1,y])+luminance(img[x,y])+luminance(img[x+1,y]))/3
        best=max(best,v)
    end
    @inbounds peaks[i]=best
end
@inline function page_poly(coeff,u,v)
    s=0f0;k=1
    for a in 0:4,b in 0:4-a
        @inbounds s+=coeff[k]*u^a*v^b
        k+=1
    end
    s
end
@kernel function page_grid!(grid,@Const(coeff),w::Int,h::Int,bw::Int)
    k=@index(Global);bx=mod(k-1,bw)+1;by=(k-1)÷bw+1
    u=Float32(((bx-0.5)*24+0.5)/w*2-1);v=Float32(((by-0.5)*24+0.5)/h*2-1)
    @inbounds grid[k]=page_poly(coeff,u,v)
end
@inline page_paper(grid,x,y)=max(sample(grid,(x-0.5f0)/24+0.5f0,(y-0.5f0)/24+0.5f0),0.05f0)
@kernel function page_tint!(partial,@Const(img),@Const(grid),w::Int,n::Int)
    k=@index(Global);r=0f0;g=0f0;b=0f0;count=0f0
    for i in ((k-1)*1024+1):min(k*1024,n)
        x=mod(i-1,w)+1;y=(i-1)÷w+1
        @inbounds c=img[i]
        if luminance(c)>=0.9f0*page_paper(grid,x,y)
            r+=red(c);g+=green(c);b+=blue(c);count+=1f0
        end
    end
    @inbounds begin partial[1,k]=r;partial[2,k]=g;partial[3,k]=b;partial[4,k]=count;end
end
@kernel function page_gain!(gain,@Const(partial),n::Int)
    k=@index(Global)
    r=0f0;g=0f0;b=0f0;count=0f0
    for i in 1:n
        @inbounds begin r+=partial[1,i];g+=partial[2,i];b+=partial[3,i];count+=partial[4,i];end
    end
    if count>0f0
        r/=count;g/=count;b/=count
    else
        r=1f0;g=1f0;b=1f0
    end
    l=0.299f0*r+0.587f0*g+0.114f0*b
    @inbounds begin gain[1]=r>0f0 ? l/r : 1f0;gain[2]=g>0f0 ? l/g : 1f0;gain[3]=b>0f0 ? l/b : 1f0;end
end
@kernel function page_flat!(out,@Const(img),@Const(grid),@Const(gain),w::Int)
    i=@index(Global);x=mod(i-1,w)+1;y=(i-1)÷w+1
    p=page_paper(grid,x,y)
    @inbounds begin c=img[i];out[i]=RGB{Float32}(red(c)*gain[1]/p,green(c)*gain[2]/p,blue(c)*gain[3]/p);end
end
@kernel function page_stretch!(img,@Const(low))
    i=@index(Global)
    @inbounds begin
        c=img[i];l=low[1]
        img[i]=RGB{Float32}(clamp((red(c)-l)/(1f0-l),0f0,1f0),clamp((green(c)-l)/(1f0-l),0f0,1f0),clamp((blue(c)-l)/(1f0-l),0f0,1f0))
    end
end
@kernel function page_ink!(counts,@Const(img),w::Int,h::Int,n::Int)
    k=@index(Global);count=Int32(0);mx=round(Int,0.04*w);my=round(Int,0.04*h)
    for i in ((k-1)*1024+1):min(k*1024,n)
        x=mod(i-1,w)+1;y=(i-1)÷w+1
        if mx<x<=w-mx && my<y<=h-my
            @inbounds count+=Int32(luminance(img[i])<0.5f0)
        end
    end
    @inbounds counts[k]=count
end
@kernel function page_rotate!(dst,@Const(src),@Const(rotation),w::Int,h::Int)
    i=@index(Global);d=Int(rotation[1]);W=(d==90 || d==270) ? h : w
    x=mod(i-1,W)+1;y=(i-1)÷W+1
    sx=d==90 ? y : d==180 ? w-x+1 : d==270 ? w-y+1 : x
    sy=d==90 ? h-x+1 : d==180 ? h-y+1 : d==270 ? x : y
    @inbounds dst[i]=src[sx,sy]
end
@kernel function page_pack!(dst,@Const(src))
    i=@index(Global)
    @inbounds c=src[i]
    r=reinterpret(N0f8,unsafe_trunc(UInt8,round(clamp(red(c),0f0,1f0)*255f0)))
    g=reinterpret(N0f8,unsafe_trunc(UInt8,round(clamp(green(c),0f0,1f0)*255f0)))
    b=reinterpret(N0f8,unsafe_trunc(UInt8,round(clamp(blue(c),0f0,1f0)*255f0)))
    @inbounds dst[i]=RGB{N0f8}(r,g,b)
end

# Host-side OCR results, refilled for every line.
mutable struct GPUOCRBuffers
    box::Vector{Float32}
    logits::Array{Float32,2}
    best::Dict{Int,Any}
    index::Dict{Int,Any}
    count::Vector{Int32}
    shape::Vector{Int32}
    boxes::Matrix{Float32}
end
GPUOCRBuffers()=GPUOCRBuffers(zeros(Float32,5),zeros(Float32,4,1),Dict{Int,Any}(),Dict{Int,Any}(),
    zeros(Int32,1),zeros(Int32,2),zeros(Float32,4,4096))

mutable struct GPUPageWorkspace{D,H}
    device::D
    dims::Tuple{Int,Int}
    input_type::DataType
    buffers::Dict{Symbol,Any}
    plans::Dict{Any,Any}
    host::H
    ocr::GPUOCRBuffers
end

function page_buffer!(s,name,T,dims)
    get!(s.buffers,name) do
        GM.Buffer(s.device,T,dims)
    end
end
function page_run!(s,key,kernel,args,n)
    p=get!(s.plans,key) do
        g=GM.Graph(s.device)
        GM.dispatch!(g,kernel,args,n;name=string(key))
        GM.record!(GM.Plan(g))
    end
    GM.run!(p)
    nothing
end
function Base.close(s::GPUPageWorkspace)
    GM.waitidle(s.device)
    foreach(GM.free!,values(s.plans));empty!(s.plans)
    foreach(GM.free!,values(s.buffers));empty!(s.buffers)
    nothing
end
function GPUPageWorkspace(m,dims,T,source_dims=dims)
    w,h=dims;bw=cld(w,24);bh=cld(h,24);n=bw*bh
    A=Matrix{Float64}(undef,n,15)
    for by in 1:bh,bx in 1:bw
        u=((bx-0.5)*24+0.5)/w*2-1;v=((by-0.5)*24+0.5)/h*2-1
        k=1
        for a in 0:4,b in 0:4-a
            A[bx+(by-1)*bw,k]=u^a*v^b;k+=1
        end
    end
    step=max(1,w*h÷200_000);ns=length(1:step:w*h)
    host=(A=A,matrix=zeros(Float32,9),rotation=zeros(Int32,1),ink=zeros(Int32,cld(w*h,1024)))
    s=GPUPageWorkspace(m.det.device,dims,T,Dict{Symbol,Any}(),Dict{Any,Any}(),host,GPUOCRBuffers())
    for (name,t,shape) in ((:input,T,source_dims),(:page,RGB{Float32},dims),(:flat,RGB{Float32},dims),
        (:rotated,RGB{Float32},dims),(:packed,RGB{N0f8},dims),(:peaks,Float32,(n,)),
        (:grid,Float32,(bw,bh)),(:coeff,Float32,(15,)),(:gain,Float32,(3,)),
        (:tint,Float32,(4,cld(w*h,1024))),(:low,Float32,(1,)),
        (:rotation,Int32,(1,)),(:ink,Int32,(cld(w*h,1024),)))
        page_buffer!(s,name,t,shape)
    end
    s
end
"""
    PageReader(model)

PP-OCRv6 and the page buffers sized for the last page, owned together by the
thread that loaded the model. `close` frees both there.
"""
mutable struct PageReader{M}
    model::M
    workspace::Union{Nothing,GPUPageWorkspace}
end
PageReader(model)=PageReader(model,nothing)

function Base.close(r::PageReader)
    r.workspace===nothing || close(r.workspace)
    r.workspace=nothing
    close(r.model)
end

# The page buffers for `img`, made again when the page size or type changes.
function gpu_workspace(r::PageReader,img;dims=size(img))
    s=r.workspace
    if s===nothing || s.dims!=dims || s.input_type!=eltype(img) || size(GM.storage(s.buffers[:input]))!=size(img)
        s===nothing || close(s)
        r.workspace=nothing
        s=GPUPageWorkspace(r.model,dims,eltype(img),size(img))
        r.workspace=s
    end
    s
end

@kernel function page_ocr_resize!(out,@Const(img),w::Int,h::Int,W::Int,H::Int,orientation::Bool)
    i=@index(Global);u=mod(i-1,W)+1;v=mod((i-1)÷W,H)+1;c=(i-1)÷(W*H)+1
    s=orientation ? PPOCRRunner.ORI_SHORT/min(w,h) : min(W/w,H/h)
    cx=orientation ? (round(Int,w*s)-W)÷2 : 0
    cy=orientation ? (round(Int,h*s)-H)÷2 : 0
    px=1f0
    if orientation || (u<=round(Int,w*s) && v<=round(Int,h*s))
        f=1/s
        rgb=PPOCRRunner.area(img,(cx+u-1)*f,(cx+u)*f,(cy+v-1)*f,(cy+v)*f)
        px=rgb[c]
    end
    @inbounds out[i]=(px-PPOCRRunner.DET_MEAN[c])/PPOCRRunner.DET_STD[c]
end
@kernel function page_line_resize!(out,@Const(img),@Const(box),W::Int)
    i=@index(Global);u=mod(i-1,W)+1;v=mod((i-1)÷W,48)+1;c=(i-1)÷(W*48)+1
    @inbounds begin bx0=box[1];by0=box[2];bw=max(box[3]-bx0,1f0);bh=max(box[4]-by0,1f0);rw=Int(box[5]);end
    val=0f0
    if u<=rw
        px=PPOCRRunner.bilinear(img,bx0+(u-0.5f0)*(bw/rw)+0.5f0,by0+(v-0.5f0)*(bh/48)+0.5f0)
        val=(px[c]-0.5f0)/0.5f0
    end
    @inbounds out[i]=val
end

function gpu_orientation(s,m)
    w,h=s.dims;W=PPOCRRunner.ORI_SIZE
    page_run!(s,:orientation_input,page_ocr_resize!,(m.oriinput,s.buffers[:flat],w,h,W,W,true),W*W*3)
    out=first(GD.call(m.ori,"ppocr_docori",m.oriinput;dims=(;)))
    scratch=s.ocr
    copyto!(scratch.logits,reshape(out,4,1))
    mod(360-90*(argmax(vec(scratch.logits))-1),360)
end

function gpu_recognize(s,m,pixels,box;retry::Bool=true)
    bw=max(box[3]-box[1],1f0);bh=max(box[4]-box[2],1f0)
    rw=clamp(ceil(Int,48*bw/bh),1,last(PPOCRRunner.REC_WIDTHS))
    line=gpu_recognize_width(s,m,pixels,box,rw)
    # A curved line needs a taller box. Scaling that box to 48 px also makes
    # its letters narrower; the recognizer can then lose most of the text.
    # Retry uncertain lines once with more horizontal samples. Reuse the
    # existing fixed-width plans, and decode positions using the new scale.
    if retry && line.score<0.8f0 && rw<last(PPOCRRunner.REC_WIDTHS)
        yield()
        wider=min(cld(3rw,2),last(PPOCRRunner.REC_WIDTHS))
        candidate=gpu_recognize_width(s,m,pixels,box,wider)
        candidate.score>line.score && return candidate
    end
    line
end

function gpu_recognize_width(s,m,pixels,box,rw)
    scratch=s.ocr
    W=PPOCRRunner.REC_WIDTHS[findfirst(>=(rw),PPOCRRunner.REC_WIDTHS)]
    for k in 1:4;scratch.box[k]=box[k];end
    scratch.box[5]=rw
    params=page_buffer!(s,:line_box,Float32,(5,));copyto!(params,scratch.box)
    input=get!(() -> KA.allocate(m.backend,Float32,W,48,3,1),m.recinputs,W)
    page_run!(s,(:line_input,W,size(pixels)),page_line_resize!,(input,pixels,params,W),W*48*3)
    best,index=GD.call(m.rec,"ppocrv6_rec",input;dims=(w=W÷16,))
    hb=get!(() -> Array{eltype(best)}(undef,size(best)),scratch.best,W)
    hi=get!(() -> Array{eltype(index)}(undef,size(index)),scratch.index,W)
    copyto!(hb,best);copyto!(hi,index)
    gpu_decode_line(m,vec(hb),vec(hi),W,rw,box)
end

function gpu_decode_line(m,best,index,W,rw,box)
    T = length(index)
    chars, steps, probs = String[], Int[], Float32[]
    previous = 0
    for t in 1:T
        k = Int(index[t])
        if k != 0 && k != previous
            push!(chars, m.characters[k + 1])
            push!(steps, t)
            push!(probs, best[t])
        end
        previous = k
    end
    # Input pixels per step, and page pixels per input pixel.
    step = W / T
    f = (box[3] - box[1]) / rw
    xpage(t) = box[1] + Float32((t - 0.5f0) * step * f)
    words = Tuple{String, Float32, Float32}[]
    i = 1
    while i <= length(chars)
        if isempty(strip(chars[i]))
            i += 1
            continue
        end
        j = i
        while j < length(chars) && !isempty(strip(chars[j + 1]))
            j += 1
        end
        half = Float32(step * f / 2)
        push!(words, (join(chars[i:j]), max(box[1], xpage(steps[i]) - half), min(box[3], xpage(steps[j]) + half)))
        i = j + 1
    end
    score = isempty(probs) ? 0.0f0 : sum(probs) / length(probs)
    return PPOCRRunner.TextLine(strip(join(chars)), box, score, words)
end


@kernel function page_warp!(out,@Const(src),@Const(matrix),w::Int,quantized::Bool)
    i=@index(Global);x=Float32(mod(i-1,w)+1);y=Float32((i-1)÷w+1)
    @inbounds begin
        z=matrix[7]*x+matrix[8]*y+matrix[9]
        sx=(matrix[1]*x+matrix[2]*y+matrix[3])/z
        sy=(matrix[4]*x+matrix[5]*y+matrix[6])/z
        c=sample(src,sx,sy)
        if quantized
            c=RGB{Float32}(round(clamp(red(c),0f0,1f0)*255f0)/255f0,round(clamp(green(c),0f0,1f0)*255f0)/255f0,round(clamp(blue(c),0f0,1f0)*255f0)/255f0)
        end
        out[i]=c
    end
end
@kernel function page_uv_input!(out,@Const(src),w::Int,h::Int)
    i=@index(Global);x=mod(i-1,488)+1;y=mod((i-1)÷488,712)+1;c=(i-1)÷(488*712)+1
    px=UVDocRunner.sample(src,1f0+(x-1)*Float32((w-1)/487),1f0+(y-1)*Float32((h-1)/711))
    @inbounds out[i]=px[c]
end
@kernel function page_uv_warp!(out,@Const(src),@Const(grid),w::Int,h::Int,gw::Int,gh::Int)
    i=@index(Global);x=mod(i-1,w)+1;y=(i-1)÷w+1
    gx=min(1f0+(x-1)*Float32((gw-1)/max(w-1,1)),Float32(gw))
    gy=min(1f0+(y-1)*Float32((gh-1)/max(h-1,1)),Float32(gh))
    a=floor(Int,gx);b=floor(Int,gy);c=min(a+1,gw);d=min(b+1,gh)
    uv=ntuple(2) do k
        @inbounds UVDocRunner.mix(UVDocRunner.mix(grid[a,b,k,1],grid[c,b,k,1],gx-a),
            UVDocRunner.mix(grid[a,d,k,1],grid[c,d,k,1],gx-a),gy-b)
    end
    px=(uv[1]+1f0)*0.5f0*(w-1)+1f0;py=(uv[2]+1f0)*0.5f0*(h-1)+1f0
    rgb=(0f0,0f0,0f0)
    if px>0 && px<w+1 && py>0 && py<h+1
        ix=floor(Int,px);iy=floor(Int,py)
        rgb=UVDocRunner.mix(UVDocRunner.mix(UVDocRunner.pixel_or_zero(src,ix,iy),UVDocRunner.pixel_or_zero(src,ix+1,iy),px-ix),
            UVDocRunner.mix(UVDocRunner.pixel_or_zero(src,ix,iy+1),UVDocRunner.pixel_or_zero(src,ix+1,iy+1),px-ix),py-iy)
    end
    @inbounds out[i]=RGB{Float32}(rgb...)
end

function gpu_upload!(s,img;corners=nothing,dewarper=nothing)
    b=s.buffers;w,h=s.dims
    copyto!(b[:input],img)
    if corners===nothing
        page_run!(s,:copy,page_copy!,(b[:page],b[:input]),w*h)
    else
        # Reject invalid geometry on the host before an unchecked GPU sampler
        # can see NaN coordinates or a projective pole inside the page.
        all(p->all(isfinite,p),corners) || throw(ArgumentError("crop corners must be finite"))
        target=(Vec2f(0.5,0.5),Vec2f(w+0.5,0.5),Vec2f(w+0.5,h+0.5),Vec2f(0.5,h+0.5))
        matrix=homography(target,portrait(corners))
        all(isfinite,matrix) || throw(ArgumentError("degenerate crop geometry"))
        denominators=map(p->matrix[3,1]*p[1]+matrix[3,2]*p[2]+matrix[3,3],target)
        (all(>(0),denominators) || all(<(0),denominators)) ||
            throw(ArgumentError("crop geometry crosses a projective pole"))
        for i in 1:3,j in 1:3;s.host.matrix[(i-1)*3+j]=matrix[i,j];end
        params=page_buffer!(s,:homography,Float32,(9,));copyto!(params,s.host.matrix)
        # Interpolate the same Float32 representation used by cleanup/OCR.
        # Scattered reads of packed three-byte RGB/N0f8 in the combined warp
        # shader faulted on RADV; linear conversion works on both backends.
        source=page_buffer!(s,:warp_source,RGB{Float32},size(img))
        page_run!(s,:warp_input,page_copy!,(source,b[:input]),length(img))
        page_run!(s,:warp,page_warp!,(b[:page],source,params,w,eltype(img)==RGB{N0f8}),w*h)
    end
    if dewarper!==nothing
        # Both models belong to the same serialized device worker. The backward
        # grid is consumed on-device, without a CPU grid or image round-trip.
        page_run!(s,(:uv_input,objectid(dewarper.input)),page_uv_input!,(dewarper.input,b[:page],w,h),488*712*3)
        grid=only(GD.call(dewarper.model,"uvdoc",dewarper.input;dims=(;)))
        page_run!(s,(:uv_warp,objectid(dewarper.input)),page_uv_warp!,(b[:flat],b[:page],grid,w,h,size(grid,1),size(grid,2)),w*h)
        page_run!(s,:uv_copy,page_copy!,(b[:page],b[:flat]),w*h)
    end
    nothing
end

@kernel function page_gray!(dst,@Const(src))
    i=@index(Global)
    @inbounds dst[i]=Gray{N0f8}(pack_n0f8(luminance(src[i])))
end
@kernel function page_luminance!(lum,@Const(src))
    i=@index(Global)
    @inbounds lum[i]=luminance(src[i])
end
# Sauvola's threshold in two passes: sums along rows, then down columns, of
# the luminance and its square over a (2r+1)² window clipped at the border.
@kernel function page_row_sums!(s1,s2,@Const(lum),W::Int,r::Int)
    i=@index(Global);x=mod(i-1,W)+1;y=(i-1)÷W+1
    a=0f0;b=0f0
    for xx in max(1,x-r):min(W,x+r)
        @inbounds v=lum[xx+(y-1)*W]
        a+=v;b+=v*v
    end
    @inbounds begin s1[i]=a;s2[i]=b;end
end
@kernel function page_sauvola!(out,@Const(lum),@Const(s1),@Const(s2),W::Int,H::Int,r::Int,k::Float32,range::Float32)
    i=@index(Global);x=mod(i-1,W)+1;y=(i-1)÷W+1
    a=0f0;b=0f0
    for yy in max(1,y-r):min(H,y+r)
        @inbounds begin a+=s1[x+(yy-1)*W];b+=s2[x+(yy-1)*W];end
    end
    n=Float32((min(W,x+r)-max(1,x-r)+1)*(min(H,y+r)-max(1,y-r)+1))
    mean=a/n;sd=sqrt(max(b/n-mean*mean,0f0))
    @inbounds out[i]=Gray{Bool}(lum[i]>mean*(1f0+k*(sd/range-1f0)))
end

"""
    gpu_pack(s, mode, dims) -> Matrix

The rotated page in `dims` as `:gray` (`Gray{N0f8}`) or `:bw` (`Gray{Bool}`,
Sauvola's threshold: a pixel is ink when it is darker than its neighbourhood's
mean by more than the neighbourhood's spread allows, so faint pencil next to a
dark heading both survive).
"""
function gpu_pack(s,mode::Symbol,dims;window::Int=31,k=0.2f0,range=0.5f0)
    n=prod(dims);W,H=dims;src=s.buffers[:rotated]
    if mode===:gray
        out=page_buffer!(s,:gray,Gray{N0f8},(n,))
        page_run!(s,:gray,page_gray!,(out,src),n)
        image=Matrix{Gray{N0f8}}(undef,dims)
    elseif mode===:bw
        lum=page_buffer!(s,:luminance,Float32,(n,))
        s1=page_buffer!(s,:row_sums,Float32,(n,));s2=page_buffer!(s,:row_squares,Float32,(n,))
        out=page_buffer!(s,:bw,Gray{Bool},(n,))
        plan=get!(s.plans,(:bw,dims)) do
            g=GM.Graph(s.device)
            GM.dispatch!(g,page_luminance!,(lum,src),n;name="luminance")
            GM.dispatch!(g,page_row_sums!,(s1,s2,lum,W,window÷2),n;name="Sauvola row sums")
            GM.dispatch!(g,page_sauvola!,(out,lum,s1,s2,W,H,window÷2,Float32(k),Float32(range)),n;name="Sauvola threshold")
            GM.record!(GM.Plan(g))
        end
        GM.run!(plan)
        image=Matrix{Gray{Bool}}(undef,dims)
    else
        throw(ArgumentError("mode must be :color, :gray or :bw, not $(repr(mode))"))
    end
    copyto!(vec(image),out)
    image
end

function gpu_page(r::PageReader,img;corners=nothing,dpi=300,paper::Symbol=:a4,mode::Symbol=:color,dewarper=nothing,rotation=nothing,image_ready=(_->nothing),recognize=true,output_buffer=nothing)
    mode in (:color,:gray,:bw) || throw(ArgumentError("mode must be :color, :gray or :bw, not $(repr(mode))"))
    dims=corners===nothing ? size(img) : page_size(corners,paper;dpi)
    min(dims...)>=120 || throw(ArgumentError("GPU page cleanup needs both output dimensions >= 120 pixels"))
    s=gpu_workspace(r,img;dims);m=r.model
    gpu_upload!(s,img;corners,dewarper)
    blank=gpu_cleanup!(s)
    degrees=rotation===nothing ? (blank ? 0 : gpu_orientation(s,m)) : mod(rotation,360)
    degrees in (0,90,180,270) || throw(ArgumentError("can only rotate by multiples of 90 degrees"))
    s.host.rotation[1]=degrees;copyto!(s.buffers[:rotation],s.host.rotation)
    w,h=s.dims
    page_run!(s,:rotate,page_rotate!,(s.buffers[:rotated],s.buffers[:flat],s.buffers[:rotation],w,h),w*h)
    dims=degrees in (90,270) ? (h,w) : (w,h)
    pixels=reshape(GM.storage(s.buffers[:rotated]),dims)
    image=if mode===:color
        page_run!(s,:pack,page_pack!,(s.buffers[:packed],s.buffers[:rotated]),w*h)
        # Public calls own the result. The draft writer may explicitly lend a
        # buffer, held until both encoding and OCR finish before it is reused.
        out=output_buffer===nothing ? nothing : output_buffer[]
        if !(out isa Matrix{RGB{N0f8}}) || size(out)!=dims
            out=Matrix{RGB{N0f8}}(undef,dims)
            output_buffer===nothing || (output_buffer[]=out)
        end
        copyto!(reshape(out,s.dims),s.buffers[:packed])
        out
    else
        gpu_pack(s,mode,dims)
    end
    image_ready(image)
    words=Word[]
    if !blank && recognize
        for box in gpu_boxes(s,m,pixels)
            line=gpu_recognize(s,m,pixels,box)
            x0,y0,x1,y1=line.box;top=round(Int,y0);height=max(1,round(Int,y1-y0))
            for (t,a,b) in line.words
                push!(words,Word(t,round(Int,a),top,max(1,round(Int,b-a)),height,top,height,100line.score))
            end
            yield()
        end
    end
    (;image,words,blank,rotation=degrees)
end

gpu_flatten!(s,img)=(gpu_upload!(s,img);gpu_cleanup!(s))

# GPU connected components: monotone union-find (larger roots hook to smaller
# roots), followed by root statistics and compact boxes. No probability map is
# copied to the CPU. The output capacity is checked, never silently truncated.
@kernel function page_cc_init!(parents,stats,sums,counter,@Const(prob),W::Int)
    k=@index(Global)
    @inbounds begin
        parents[k]=prob[k]>0.3f0 ? Int32(k) : Int32(0)
        stats[1,k]=typemax(Int32);stats[2,k]=typemax(Int32)
        stats[3,k]=0;stats[4,k]=0;stats[5,k]=0;sums[k]=0f0
        k==1 && (counter[1]=0)
    end
end
@inline function page_cc_root(parents,k::Int32)
    p=KA.@atomic :monotonic parents[k]
    while p!=k
        k=p;p=KA.@atomic :monotonic parents[k]
    end
    k
end
@inline function page_cc_join!(parents,a::Int32,b::Int32)
    while true
        a=page_cc_root(parents,a);b=page_cc_root(parents,b)
        a==b && break
        hi=max(a,b);lo=min(a,b)
        result=KA.@atomicreplace :monotonic parents[hi] hi=>lo
        result.success && break
    end
    nothing
end
@kernel function page_cc_merge!(parents,@Const(prob),W::Int,H::Int)
    k=@index(Global);x=mod(k-1,W)+1;y=(k-1)÷W+1
    if @inbounds prob[k]>0.3f0
        if x>1 && (@inbounds prob[k-1]>0.3f0)
            page_cc_join!(parents,Int32(k),Int32(k-1))
        end
        if y>1
            for dx in -1:1
                j=k-W+dx
                if 1<=x+dx<=W && (@inbounds prob[j]>0.3f0)
                    page_cc_join!(parents,Int32(k),Int32(j))
                end
            end
        end
    end
end
@kernel function page_cc_stats!(stats,sums,@Const(parents),@Const(prob),W::Int)
    k=@index(Global)
    if @inbounds parents[k]!=0
        root=Int32(k)
        while (@inbounds parents[root])!=root
            @inbounds root=parents[root]
        end
        x=Int32(mod(k-1,W)+1);y=Int32((k-1)÷W+1)
        KA.@atomic min(stats[1,root],x)
        KA.@atomic min(stats[2,root],y)
        KA.@atomic max(stats[3,root],x)
        KA.@atomic max(stats[4,root],y)
        KA.@atomic stats[5,root] += Int32(1)
        KA.@atomic sums[root] += prob[k]
    end
end
@kernel function page_cc_boxes!(boxes,counter,@Const(stats),@Const(sums),@Const(shape),W::Int,H::Int,capacity::Int)
    k=@index(Global)
    @inbounds begin
        count=stats[5,k];x0=stats[1,k];y0=stats[2,k];x1=stats[3,k];y1=stats[4,k]
        bw=x1-x0+1;bh=y1-y0+1
        if count>0 && min(bw,bh)>=3 && sums[k]/count>=0.6f0
            d=Float32(bw)*Float32(bh)*1.5f0/(2f0*(bw+bh))
            if min(bw,bh)+2d>=5f0
                slot=KA.@atomic counter[1]+=Int32(1)
                if slot<=capacity
                    w=shape[1];h=shape[2];scale=min(W/Float32(w),H/Float32(h))
                    boxes[1,slot]=max(0f0,(x0-1-d)/scale);boxes[2,slot]=max(0f0,(y0-1-d)/scale)
                    boxes[3,slot]=min(Float32(w),(x1+d)/scale);boxes[4,slot]=min(Float32(h),(y1+d)/scale)
                end
            end
        end
    end
end

const GPU_BOX_CAPACITY=4096
function gpu_component_boxes(s,m,prob,dims)
    W,H=m.page;n=W*H;scratch=s.ocr
    parents=page_buffer!(s,:cc_parents,Int32,(n,))
    stats=page_buffer!(s,:cc_stats,Int32,(5,n))
    sums=page_buffer!(s,:cc_sums,Float32,(n,))
    counter=page_buffer!(s,:cc_count,Int32,(1,))
    boxes=page_buffer!(s,:cc_boxes,Float32,(4,GPU_BOX_CAPACITY))
    shape=page_buffer!(s,:cc_shape,Int32,(2,))
    scratch.shape.=dims;copyto!(shape,scratch.shape)
    plan=get!(s.plans,:components) do
        g=GM.Graph(s.device)
        GM.dispatch!(g,page_cc_init!,(parents,stats,sums,counter,prob,W),n;name="component initialization")
        GM.dispatch!(g,page_cc_merge!,(parents,prob,W,H),n;name="component union")
        GM.dispatch!(g,page_cc_stats!,(stats,sums,parents,prob,W),n;name="component statistics")
        GM.dispatch!(g,page_cc_boxes!,(boxes,counter,stats,sums,shape,W,H,GPU_BOX_CAPACITY),n;name="compact boxes")
        GM.record!(GM.Plan(g))
    end
    GM.run!(plan)
    copyto!(scratch.count,counter);count=Int(scratch.count[1])
    count<=GPU_BOX_CAPACITY || throw(ArgumentError("detector exceeded $GPU_BOX_CAPACITY text regions; image retained for review"))
    copyto!(scratch.boxes,1,GM.storage(boxes),1,4count)
    found=[ntuple(j->scratch.boxes[j,k],4) for k in 1:count]
    PPOCRRunner.reading_order(found)
end

function gpu_boxes(s,m,pixels)
    W,H=m.page;w,h=size(pixels)
    page_run!(s,(:detector_input,w,h),page_ocr_resize!,(m.detinput,pixels,w,h,W,H,false),W*H*3)
    out=first(GD.call(m.det,"ppocrv6_det",m.detinput;dims=(;)))
    gpu_component_boxes(s,m,out,(w,h))
end

@kernel function page_fit_parts!(parts,@Const(A),@Const(peaks),@Const(coeff),n::Int,iteration::Int)
    k=@index(Global);term=mod(k-1,240)+1;chunk=(k-1)÷240+1
    row=mod(term-1,15)+1;col=(term-1)÷15+1;total=0.0
    for i in ((chunk-1)*256+1):min(chunk*256,n)
        predicted=0.0
        if iteration>0
            for j in 1:15
                @inbounds predicted+=A[i,j]*coeff[j]
            end
        end
        if iteration==0 || (@inbounds peaks[i]>=predicted*(1-0.08f0))
            @inbounds total+=A[i,row]*(col<=15 ? A[i,col] : Float64(peaks[i]))
        end
    end
    @inbounds parts[term,chunk]=total
end
@kernel function page_fit_solve!(coeff,normal,@Const(parts),groups::Int)
    k=@index(Global)
    for col in 1:16,row in 1:15
        total=0.0
        for g in 1:groups
            @inbounds total+=parts[row+(col-1)*15,g]
        end
        @inbounds normal[row,col]=total
    end
    # Cholesky and two triangular solves for 15 polynomial coefficients.
    # A tiny diagonal regularizer keeps a nearly empty selected set finite.
    @inbounds ridge=max(normal[1,1],1.0)*1e-12
    for j in 1:15
        @inbounds v=normal[j,j]+ridge
        for p in 1:j-1
            @inbounds v-=normal[j,p]^2
        end
        @inbounds normal[j,j]=sqrt(max(v,ridge))
        for i in j+1:15
            @inbounds v=normal[i,j]
            for p in 1:j-1
                @inbounds v-=normal[i,p]*normal[j,p]
            end
            @inbounds normal[i,j]=v/normal[j,j]
        end
    end
    for i in 1:15
        @inbounds v=normal[i,16]
        for j in 1:i-1
            @inbounds v-=normal[i,j]*coeff[j]
        end
        @inbounds coeff[i]=v/normal[i,i]
    end
    for i in 15:-1:1
        @inbounds v=coeff[i]
        for j in i+1:15
            @inbounds v-=normal[j,i]*coeff[j]
        end
        @inbounds coeff[i]=v/normal[i,i]
    end
end
@kernel function page_coeff_cast!(out,@Const(coeff))
    i=@index(Global);@inbounds out[i]=Float32(coeff[i])
end
@kernel function page_quantile_init!(state,k::UInt32)
    i=@index(Global)
    @inbounds begin state[1]=0;state[2]=k;end
end
@kernel function page_zero!(out)
    i=@index(Global);@inbounds out[i]=zero(eltype(out))
end
@kernel function page_quantile_hist!(hist,@Const(img),@Const(state),step::Int,shift::Int)
    i=@index(Global)
    @inbounds bits=reinterpret(UInt32,luminance(img[1+(i-1)*step]))
    @inbounds prefix=state[1]
    mask=shift==24 ? UInt32(0) : typemax(UInt32)<<(shift+8)
    if bits&mask==prefix
        bin=Int((bits>>shift)&UInt32(255))+1;group=(i-1)÷256+1
        KA.@atomic hist[bin,group]+=Int32(1)
    end
end
@kernel function page_quantile_counts!(counts,@Const(hist),groups::Int)
    i=@index(Global);n=Int32(0)
    for g in 1:groups
        @inbounds n+=hist[i,g]
    end
    @inbounds counts[i]=n
end
@kernel function page_quantile_pick!(state,low,@Const(counts),shift::Int)
    i=@index(Global);@inbounds k=Int32(state[2]);bin=1
    while bin<256 && k>(@inbounds counts[bin])
        @inbounds k-=counts[bin];bin+=1
    end
    @inbounds begin
        state[1]=state[1]|(UInt32(bin-1)<<shift);state[2]=UInt32(k)
        shift==0 && (low[1]=min(reinterpret(Float32,state[1]),0.4f0))
    end
end

function gpu_cleanup!(s)
    b=s.buffers;w,h=s.dims;n=w*h;nb=cld(w,24)*cld(h,24);groups=cld(nb,256)
    plan=get!(s.plans,:cleanup) do
        A=page_buffer!(s,:fit_design,Float64,size(s.host.A));copyto!(A,s.host.A)
        coeff=page_buffer!(s,:fit_coeff,Float64,(15,))
        normal=page_buffer!(s,:fit_normal,Float64,(15,16))
        parts=page_buffer!(s,:fit_parts,Float64,(240,groups))
        step=max(1,n÷200_000);ns=length(1:step:n);ng=cld(ns,256)
        hist=page_buffer!(s,:quantile_hist,Int32,(256,ng))
        counts=page_buffer!(s,:quantile_counts,Int32,(256,))
        state=page_buffer!(s,:quantile_state,UInt32,(2,))
        g=GM.Graph(s.device)
        GM.dispatch!(g,page_peaks!,(b[:peaks],b[:page],w,h,cld(w,24)),nb;name="paper block maxima")
        for iteration in 0:4
            GM.dispatch!(g,page_fit_parts!,(parts,A,b[:peaks],coeff,nb,iteration),240groups;name="paper fit products $iteration")
            GM.dispatch!(g,page_fit_solve!,(coeff,normal,parts,groups),1;name="paper fit solve $iteration")
        end
        GM.dispatch!(g,page_coeff_cast!,(b[:coeff],coeff),15;name="paper coefficients")
        GM.dispatch!(g,page_grid!,(b[:grid],b[:coeff],w,h,cld(w,24)),nb;name="paper grid")
        GM.dispatch!(g,page_tint!,(b[:tint],b[:page],b[:grid],w,n),cld(n,1024);name="paper color sums")
        GM.dispatch!(g,page_gain!,(b[:gain],b[:tint],cld(n,1024)),1;name="white balance")
        GM.dispatch!(g,page_flat!,(b[:flat],b[:page],b[:grid],b[:gain],w),n;name="lighting correction")
        GM.dispatch!(g,page_quantile_init!,(state,UInt32(clamp(round(Int,0.005ns),1,ns))),1;name="contrast selection")
        for shift in (24,16,8,0)
            GM.dispatch!(g,page_zero!,(hist,),256ng;name="clear contrast histogram $shift")
            GM.dispatch!(g,page_quantile_hist!,(hist,b[:flat],state,step,shift),ns;name="contrast histogram $shift")
            GM.dispatch!(g,page_quantile_counts!,(counts,hist,ng),256;name="contrast counts $shift")
            GM.dispatch!(g,page_quantile_pick!,(state,b[:low],counts,shift),1;name="contrast select byte $shift")
        end
        GM.dispatch!(g,page_stretch!,(b[:flat],b[:low]),n;name="contrast stretch")
        GM.dispatch!(g,page_ink!,(b[:ink],b[:flat],w,h,n),cld(n,1024);name="blank detection")
        GM.record!(GM.Plan(g))
    end
    GM.run!(plan)
    copyto!(s.host.ink,b[:ink])
    sum(s.host.ink)/((w-2round(Int,0.04w))*(h-2round(Int,0.04h)))<0.001
end

function gpu_read_lines(r::PageReader,img)
    isempty(img) && throw(ArgumentError("OCR input must be nonempty"))
    s=gpu_workspace(r,img);b=s.buffers;m=r.model
    copyto!(b[:input],img)
    page_run!(s,:read_input,page_copy!,(b[:rotated],b[:input]),length(img))
    pixels=GM.storage(b[:rotated])
    lines=PPOCRRunner.TextLine[]
    for box in gpu_boxes(s,m,pixels)
        line=gpu_recognize(s,m,pixels,box)
        isempty(line.text) || push!(lines,line)
        yield()
    end
    lines
end
function gpu_page_orientation(r::PageReader,img)
    isempty(img) && throw(ArgumentError("OCR input must be nonempty"))
    s=gpu_workspace(r,img);b=s.buffers;m=r.model
    copyto!(b[:input],img)
    page_run!(s,:orientation_copy,page_copy!,(b[:flat],b[:input]),length(img))
    gpu_orientation(s,m)
end
