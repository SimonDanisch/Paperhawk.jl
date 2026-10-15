# Preparing a captured page on the GPU: warped flat from the camera frame,
# optionally straightened by UVDoc, lighting evened out and paper made white,
# checked for being blank, turned upright and packed for the PDF. Which way up
# it is and the words on it come from PPOCRRunner, on the same device.

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

"""
    PageWorkspace

The device buffers and recorded passes for pages of one size from frames of
one size and pixel type, and the host arrays their small results come back
in. Made again when either changes; see [`workspace!`](@ref).
"""
mutable struct PageWorkspace{D, H}
    device::D
    dims::Tuple{Int, Int}
    input_type::DataType
    input_dims::Tuple{Int, Int}
    buffers::Dict{Symbol, Any}
    plans::Dict{Any, Any}
    host::H
end

function buffer!(s::PageWorkspace, name, T, dims)
    get!(s.buffers, name) do
        Mantle.Buffer(s.device, T, dims)
    end
end

function pass!(s::PageWorkspace, key, kernel, args, n)
    plan = get!(s.plans, key) do
        g = Mantle.Graph(s.device)
        Mantle.dispatch!(g, kernel, args, n; name = string(key))
        Mantle.record!(Mantle.Plan(g))
    end
    Mantle.run!(plan)
    return nothing
end

function Base.close(s::PageWorkspace)
    Mantle.waitidle(s.device)
    foreach(Mantle.free!, values(s.plans)); empty!(s.plans)
    foreach(Mantle.free!, values(s.buffers)); empty!(s.buffers)
    return nothing
end

function PageWorkspace(device, dims, T, input_dims)
    w, h = dims; bw = cld(w, 24); bh = cld(h, 24); n = bw * bh
    # The design matrix of the paper fit: a quartic in the block centres.
    A = Matrix{Float64}(undef, n, 15)
    for by in 1:bh, bx in 1:bw
        u = ((bx - 0.5) * 24 + 0.5) / w * 2 - 1; v = ((by - 0.5) * 24 + 0.5) / h * 2 - 1
        k = 1
        for a in 0:4, b in 0:4-a
            A[bx + (by - 1) * bw, k] = u^a * v^b; k += 1
        end
    end
    host = (A = A, matrix = zeros(Float32, 9), rotation = zeros(Int32, 1), ink = zeros(Int32, cld(w * h, 1024)))
    s = PageWorkspace(device, dims, T, input_dims, Dict{Symbol, Any}(), Dict{Any, Any}(), host)
    for (name, t, shape) in ((:input, T, input_dims), (:page, RGB{Float32}, dims), (:flat, RGB{Float32}, dims),
        (:packed, RGB{N0f8}, (w * h,)), (:peaks, Float32, (n,)),
        (:grid, Float32, (bw, bh)), (:coeff, Float32, (15,)), (:gain, Float32, (3,)),
        (:tint, Float32, (4, cld(w * h, 1024))), (:low, Float32, (1,)),
        (:rotation, Int32, (1,)), (:ink, Int32, (cld(w * h, 1024),)))
        buffer!(s, name, t, shape)
    end
    return s
end

"""
    cleanup!(s) -> blank

The page with its lighting evened out, paper white and contrast stretched,
into `flat`; and whether it is blank: almost no ink inside a 4% margin.
"""
function cleanup!(s::PageWorkspace)
    b=s.buffers;w,h=s.dims;n=w*h;nb=cld(w,24)*cld(h,24);groups=cld(nb,256)
    plan=get!(s.plans,:cleanup) do
        A=buffer!(s,:fit_design,Float64,size(s.host.A));copyto!(A,s.host.A)
        coeff=buffer!(s,:fit_coeff,Float64,(15,))
        normal=buffer!(s,:fit_normal,Float64,(15,16))
        parts=buffer!(s,:fit_parts,Float64,(240,groups))
        step=max(1,n÷200_000);ns=length(1:step:n);ng=cld(ns,256)
        hist=buffer!(s,:quantile_hist,Int32,(256,ng))
        counts=buffer!(s,:quantile_counts,Int32,(256,))
        state=buffer!(s,:quantile_state,UInt32,(2,))
        g=Mantle.Graph(s.device)
        Mantle.dispatch!(g,page_peaks!,(b[:peaks],b[:page],w,h,cld(w,24)),nb;name="paper block maxima")
        for iteration in 0:4
            Mantle.dispatch!(g,page_fit_parts!,(parts,A,b[:peaks],coeff,nb,iteration),240groups;name="paper fit products $iteration")
            Mantle.dispatch!(g,page_fit_solve!,(coeff,normal,parts,groups),1;name="paper fit solve $iteration")
        end
        Mantle.dispatch!(g,page_coeff_cast!,(b[:coeff],coeff),15;name="paper coefficients")
        Mantle.dispatch!(g,page_grid!,(b[:grid],b[:coeff],w,h,cld(w,24)),nb;name="paper grid")
        Mantle.dispatch!(g,page_tint!,(b[:tint],b[:page],b[:grid],w,n),cld(n,1024);name="paper color sums")
        Mantle.dispatch!(g,page_gain!,(b[:gain],b[:tint],cld(n,1024)),1;name="white balance")
        Mantle.dispatch!(g,page_flat!,(b[:flat],b[:page],b[:grid],b[:gain],w),n;name="lighting correction")
        Mantle.dispatch!(g,page_quantile_init!,(state,UInt32(clamp(round(Int,0.005ns),1,ns))),1;name="contrast selection")
        for shift in (24,16,8,0)
            Mantle.dispatch!(g,page_zero!,(hist,),256ng;name="clear contrast histogram $shift")
            Mantle.dispatch!(g,page_quantile_hist!,(hist,b[:flat],state,step,shift),ns;name="contrast histogram $shift")
            Mantle.dispatch!(g,page_quantile_counts!,(counts,hist,ng),256;name="contrast counts $shift")
            Mantle.dispatch!(g,page_quantile_pick!,(state,b[:low],counts,shift),1;name="contrast select byte $shift")
        end
        Mantle.dispatch!(g,page_stretch!,(b[:flat],b[:low]),n;name="contrast stretch")
        Mantle.dispatch!(g,page_ink!,(b[:ink],b[:flat],w,h,n),cld(n,1024);name="blank detection")
        Mantle.record!(Mantle.Plan(g))
    end
    Mantle.run!(plan)
    copyto!(s.host.ink,b[:ink])
    sum(s.host.ink)/((w-2round(Int,0.04w))*(h-2round(Int,0.04h)))<0.001
end


"""
    workspace!(reader, img, dims) -> PageWorkspace

The reader's workspace for a page of `dims` from `img`, made again when the
page size, the frame size or the pixel type changes.
"""
function workspace!(r, img::AbstractMatrix, dims::Tuple{Int, Int})
    s = r.workspace
    if s === nothing || s.dims != dims || s.input_type != eltype(img) || s.input_dims != size(img)
        s === nothing || close(s)
        r.workspace = nothing
        r.workspace = s = PageWorkspace(r.device, dims, eltype(img), size(img))
    end
    return s
end

"""
    upload!(s, img; corners = nothing)

`img` to the device, and into the page: warped flat from inside `corners`, or
taken as it is without them.
"""
function upload!(s::PageWorkspace, img::AbstractMatrix; corners = nothing)
    b = s.buffers; w, h = s.dims
    copyto!(b[:input], img)
    if corners === nothing
        pass!(s, :copy, page_copy!, (b[:page], b[:input]), w * h)
        return nothing
    end
    # Reject invalid geometry on the host before an unchecked GPU sampler
    # can see NaN coordinates or a projective pole inside the page.
    all(p -> all(isfinite, p), corners) || throw(ArgumentError("crop corners must be finite"))
    target = (Vec2f(0.5, 0.5), Vec2f(w + 0.5, 0.5), Vec2f(w + 0.5, h + 0.5), Vec2f(0.5, h + 0.5))
    matrix = homography(target, portrait(corners))
    all(isfinite, matrix) || throw(ArgumentError("degenerate crop geometry"))
    denominators = map(p -> matrix[3, 1] * p[1] + matrix[3, 2] * p[2] + matrix[3, 3], target)
    (all(>(0), denominators) || all(<(0), denominators)) ||
        throw(ArgumentError("crop geometry crosses a projective pole"))
    for i in 1:3, j in 1:3
        s.host.matrix[(i - 1) * 3 + j] = matrix[i, j]
    end
    params = buffer!(s, :homography, Float32, (9,)); copyto!(params, s.host.matrix)
    # Interpolate the same Float32 representation used by cleanup and OCR.
    # Scattered reads of packed three-byte RGB{N0f8} in the combined warp
    # shader faulted on RADV; a linear conversion first works on both backends.
    source = buffer!(s, :warp_source, RGB{Float32}, size(img))
    pass!(s, :warp_input, page_copy!, (source, b[:input]), length(img))
    pass!(s, :warp, page_warp!, (b[:page], source, params, w, eltype(img) == RGB{N0f8}), w * h)
    return nothing
end

"""
    unwarp!(reader, s)

The page straightened by UVDoc, in place, on the reader's device.
"""
function unwarp!(r, s::PageWorkspace)
    m = dewarper!(r)
    uv = UVDocRunner.pageinput!(m, s.dims)
    n = prod(s.dims)
    pass!(s, :uvdoc_in, page_copy!, (uv.pixels, s.buffers[:page]), n)
    UVDocRunner.unwarp!(m, uv)
    pass!(s, :uvdoc_out, page_copy!, (s.buffers[:page], uv.output), n)
    return nothing
end

"""
    orientation(reader, s) -> degrees

Which way up the cleaned page is, by PP-LCNet on PPOCRRunner's page input.
"""
function orientation(r, s::PageWorkspace)
    page = PPOCRRunner.pageinput!(r.model, s.dims)
    pass!(s, :orientation, page_copy!, (page.pixels, s.buffers[:flat]), prod(s.dims))
    return PPOCRRunner.orientation(r.model, page)
end

"""
    rotated!(reader, s, degrees) -> PPOCRRunner.PageInput

The cleaned page turned clockwise by `degrees`, written straight into the OCR
model's page input of the turned size.
"""
function rotated!(r, s::PageWorkspace, degrees::Int)
    w, h = s.dims
    dims = degrees in (90, 270) ? (h, w) : (w, h)
    page = PPOCRRunner.pageinput!(r.model, dims)
    s.host.rotation[1] = degrees; copyto!(s.buffers[:rotation], s.host.rotation)
    pass!(s, (:rotate, dims), page_rotate!, (page.pixels, s.buffers[:flat], s.buffers[:rotation], w, h), w * h)
    return page
end

"""
    packed(s, page, mode, output) -> Matrix

The turned page for the PDF: `:color` as `RGB{N0f8}`, `:gray` as `Gray{N0f8}`,
or `:bw` as `Gray{Bool}` by Sauvola's threshold: a pixel is ink when it is
darker than its neighbourhood's mean by more than the neighbourhood's spread
allows, so faint pencil next to a dark heading both survive. A colour result
goes into `output[]` when that has the right size and type.
"""
function packed(s::PageWorkspace, page, mode::Symbol, output; window::Int = 31, k = 0.2f0, range = 0.5f0)
    dims = size(page); n = prod(dims); W, H = dims; src = page.pixels
    if mode === :color
        pass!(s, (:pack, dims), page_pack!, (s.buffers[:packed], src), n)
        # The draft writer lends a buffer, held until both encoding and OCR
        # finish before it is reused; anyone else gets a new matrix.
        image = output === nothing ? nothing : output[]
        if !(image isa Matrix{RGB{N0f8}}) || size(image) != dims
            image = Matrix{RGB{N0f8}}(undef, dims)
            output === nothing || (output[] = image)
        end
        copyto!(vec(image), s.buffers[:packed])
    elseif mode === :gray
        out = buffer!(s, :gray, Gray{N0f8}, (n,))
        pass!(s, (:gray, dims), page_gray!, (out, src), n)
        image = Matrix{Gray{N0f8}}(undef, dims)
        copyto!(vec(image), out)
    elseif mode === :bw
        lum = buffer!(s, :luminance, Float32, (n,))
        s1 = buffer!(s, :row_sums, Float32, (n,)); s2 = buffer!(s, :row_squares, Float32, (n,))
        out = buffer!(s, :bw, Gray{Bool}, (n,))
        plan = get!(s.plans, (:bw, dims)) do
            g = Mantle.Graph(s.device)
            Mantle.dispatch!(g, page_luminance!, (lum, src), n; name = "luminance")
            Mantle.dispatch!(g, page_row_sums!, (s1, s2, lum, W, window ÷ 2), n; name = "Sauvola row sums")
            Mantle.dispatch!(g, page_sauvola!, (out, lum, s1, s2, W, H, window ÷ 2, Float32(k), Float32(range)), n; name = "Sauvola threshold")
            Mantle.record!(Mantle.Plan(g))
        end
        Mantle.run!(plan)
        image = Matrix{Gray{Bool}}(undef, dims)
        copyto!(vec(image), out)
    else
        throw(ArgumentError("mode must be :color, :gray or :bw, not $(repr(mode))"))
    end
    return image
end

