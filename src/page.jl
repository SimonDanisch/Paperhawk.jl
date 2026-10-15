# Preparing a captured page on the GPU: warped flat from the camera frame,
# optionally straightened by UVDoc, lighting evened out and paper made white,
# checked for being blank, turned upright and packed for the PDF. The general
# image operations are GPUFiltering's, declared into recorded Mantle graphs; the
# kernels here are the page's own model of its lighting. Which way up the page
# is and the words on it come from PPOCRRunner, on the same device.

# The brightest luma in each 24 x 24 block, smoothed over three pixels so one
# bright speck is not paper.
@kernel function page_peaks!(peaks,@Const(img),w::Int,h::Int,bw::Int)
    i=@index(Global)
    bx=mod(i-1,bw)+1;by=(i-1)÷bw+1
    best=0f0
    for y in ((by-1)*24+2):min(by*24,h-1),x in ((bx-1)*24+2):min(bx*24,w-1)
        @inbounds v=(GF.luma(img[x-1,y])+GF.luma(img[x,y])+GF.luma(img[x+1,y]))/3
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
# The paper's brightness under each pixel, from the fitted block grid.
@inline page_paper(grid,x,y)=max(GF.bilinear(grid,(x-0.5f0)/24+0.5f0,(y-0.5f0)/24+0.5f0),0.05f0)
@kernel function page_tint!(partial,@Const(img),@Const(grid),w::Int,n::Int)
    k=@index(Global);r=0f0;g=0f0;b=0f0;count=0f0
    for i in ((k-1)*1024+1):min(k*1024,n)
        x=mod(i-1,w)+1;y=(i-1)÷w+1
        @inbounds c=img[i]
        if GF.luma(c)>=0.9f0*page_paper(grid,x,y)
            r+=red(c);g+=green(c);b+=blue(c);count+=1f0
        end
    end
    @inbounds begin partial[1,k]=r;partial[2,k]=g;partial[3,k]=b;partial[4,k]=count;end
end
# Per-channel gains that make the paper's mean colour grey at its own luma.
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
    l=GF.luma(RGB{Float32}(r,g,b))
    @inbounds begin gain[1]=r>0f0 ? l/r : 1f0;gain[2]=g>0f0 ? l/g : 1f0;gain[3]=b>0f0 ? l/b : 1f0;end
end
@kernel function page_flat!(out,@Const(img),@Const(grid),@Const(gain),w::Int)
    i=@index(Global);x=mod(i-1,w)+1;y=(i-1)÷w+1
    p=page_paper(grid,x,y)
    @inbounds begin c=img[i];out[i]=RGB{Float32}(red(c)*gain[1]/p,green(c)*gain[2]/p,blue(c)*gain[3]/p);end
end
# The darkest half percent becomes black: `low` is that quantile, capped so a
# page that is mostly dark keeps its greys.
@kernel function page_stretch!(img,@Const(low))
    i=@index(Global)
    @inbounds begin
        c=img[i];l=min(low[1],0.4f0)
        img[i]=RGB{Float32}(clamp((red(c)-l)/(1f0-l),0f0,1f0),clamp((green(c)-l)/(1f0-l),0f0,1f0),clamp((blue(c)-l)/(1f0-l),0f0,1f0))
    end
end
@kernel function page_ink!(counts,@Const(img),w::Int,h::Int,n::Int)
    k=@index(Global);count=Int32(0);mx=round(Int,0.04*w);my=round(Int,0.04*h)
    for i in ((k-1)*1024+1):min(k*1024,n)
        x=mod(i-1,w)+1;y=(i-1)÷w+1
        if mx<x<=w-mx && my<y<=h-my
            @inbounds count+=Int32(GF.luma(img[i])<0.5f0)
        end
    end
    @inbounds counts[k]=count
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
"""
    PageWorkspace

The device arrays and recorded graphs for pages of one size from frames of one
size and pixel type, and the host arrays their small results come back in.
Made again when either changes; see [`workspace!`](@ref).
"""
struct PageWorkspace{D, H}
    dims::Tuple{Int, Int}
    input_type::DataType
    input_dims::Tuple{Int, Int}
    arrays::DeviceArrays{D}
    host::H
end

array!(s::PageWorkspace, name, T, dims) = array!(s.arrays, name, T, dims)
run!(declare, s::PageWorkspace, key) = run!(declare, s.arrays, key)
Base.close(s::PageWorkspace) = (empty!(s.arrays); nothing)

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
    host = (A = A, homography = Vector{Mat3f}(undef, 1), rotation = zeros(Int32, 1), ink = zeros(Int32, cld(w * h, 1024)))
    s = PageWorkspace(dims, T, input_dims, DeviceArrays(device), host)
    array!(s, :input, T, input_dims); array!(s, :page, RGB{Float32}, dims); array!(s, :flat, RGB{Float32}, dims)
    return s
end

"""
    cleanup!(s) -> blank

The page with its lighting evened out, paper white and contrast stretched,
into `flat`; and whether it is blank: almost no ink inside a 4% margin.
"""
function cleanup!(s::PageWorkspace)
    w, h = s.dims; n = w * h; bw = cld(w, 24); nb = bw * cld(h, 24); groups = cld(nb, 256); chunks = cld(n, 1024)
    page, flat = s.arrays[:page], s.arrays[:flat]
    ink = array!(s, :ink, Int32, (chunks,))
    run!(s, :cleanup) do g
        A = array!(s, :fit_design, Float64, size(s.host.A)); copyto!(A, s.host.A)
        coeff64 = array!(s, :fit_coeff, Float64, (15,)); normal = array!(s, :fit_normal, Float64, (15, 16))
        parts = array!(s, :fit_parts, Float64, (240, groups))
        peaks = array!(s, :peaks, Float32, (nb,)); grid = array!(s, :grid, Float32, (bw, cld(h, 24)))
        coeff = array!(s, :coeff, Float32, (15,)); gain = array!(s, :gain, Float32, (3,))
        tint = array!(s, :tint, Float32, (4, chunks)); low = array!(s, :low, Float32, (1,))
        stride = max(1, n ÷ 200_000)
        hs, cs, ss = GF.quantilesizes(n; stride)
        quantile = (array!(s, :quantile_hist, Int32, hs), array!(s, :quantile_counts, Int32, cs), array!(s, :quantile_state, UInt32, ss))
        Mantle.dispatch!(g, page_peaks!, (peaks, page, w, h, bw), nb; name = "paper block maxima")
        for iteration in 0:4
            Mantle.dispatch!(g, page_fit_parts!, (parts, A, peaks, coeff64, nb, iteration), 240groups; name = "paper fit products $iteration")
            Mantle.dispatch!(g, page_fit_solve!, (coeff64, normal, parts, groups), 1; name = "paper fit solve $iteration")
        end
        Mantle.dispatch!(g, page_coeff_cast!, (coeff, coeff64), 15; name = "paper coefficients")
        Mantle.dispatch!(g, page_grid!, (grid, coeff, w, h, bw), nb; name = "paper grid")
        Mantle.dispatch!(g, page_tint!, (tint, page, grid, w, n), chunks; name = "paper color sums")
        Mantle.dispatch!(g, page_gain!, (gain, tint, chunks), 1; name = "white balance")
        Mantle.dispatch!(g, page_flat!, (flat, page, grid, gain, w), n; name = "lighting correction")
        GF.selectquantile!(g, low, flat, 0.005, GF.luma, stride, quantile)
        Mantle.dispatch!(g, page_stretch!, (flat, low), n; name = "contrast stretch")
        Mantle.dispatch!(g, page_ink!, (ink, flat, w, h, n), chunks; name = "blank detection")
    end
    copyto!(s.host.ink, ink)
    return sum(s.host.ink) / ((w - 2round(Int, 0.04w)) * (h - 2round(Int, 0.04h))) < 0.001
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
    w, h = s.dims
    input, page = s.arrays[:input], s.arrays[:page]
    copyto!(input, img)
    if corners === nothing
        run!(g -> GF.convertpixels!(g, page, input), s, :copy)
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
    s.host.homography[1] = Mat3f(matrix)
    M = array!(s, :homography, Mat3f, (1,)); copyto!(M, s.host.homography)
    # Warp from a Float32 copy: scattered reads of packed three-byte
    # RGB{N0f8} in the warp faulted on RADV; a linear conversion works on both.
    source = array!(s, :warp_source, RGB{Float32}, size(img))
    run!(s, :warp) do g
        GF.convertpixels!(g, source, input)
        GF.warp!(g, page, source, M)
    end
    return nothing
end

"""
    unwarp!(reader, s)

The page straightened by UVDoc, in place, on the reader's device.
"""
function unwarp!(r, s::PageWorkspace)
    m = dewarper!(r)
    uv = UVDocRunner.pageinput!(m, s.dims)
    page = s.arrays[:page]
    run!(g -> GF.convertpixels!(g, Mantle.storage(uv.pixels), page), s, :uvdoc_in)
    UVDocRunner.unwarp!(m, uv)
    run!(g -> GF.convertpixels!(g, page, Mantle.storage(uv.output)), s, :uvdoc_out)
    return nothing
end

"""
    orientation(reader, s) -> degrees

Which way up the cleaned page is, by PP-LCNet on PPOCRRunner's page input.
"""
function orientation(r, s::PageWorkspace)
    page = PPOCRRunner.pageinput!(r.model, s.dims)
    run!(g -> GF.convertpixels!(g, Mantle.storage(page.pixels), s.arrays[:flat]), s, :orientation)
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
    rotation = array!(s, :rotation, Int32, (1,))
    s.host.rotation[1] = degrees; copyto!(rotation, s.host.rotation)
    run!(s, (:rotate, dims)) do g
        GF.rotate90!(g, Mantle.storage(page.pixels), s.arrays[:flat], rotation)
    end
    return page
end

"""
    packed(s, page, mode, output) -> Matrix

The turned page for the PDF: `:color` as `RGB{N0f8}`, `:gray` as `Gray{N0f8}`,
or `:bw` as `Gray{Bool}` by Sauvola's threshold (`GPUFiltering.sauvola!`). A
colour result goes into `output[]` when that has the right size and type.
"""
function packed(s::PageWorkspace, page, mode::Symbol, output; window::Int = 31, k = 0.2f0, range = 0.5f0)
    dims = size(page); src = Mantle.storage(page.pixels)
    if mode === :color
        out = array!(s, :packed, RGB{N0f8}, dims)
        run!(g -> GF.convertpixels!(g, out, src), s, (:pack, dims))
        # The draft writer lends a buffer, held until both encoding and OCR
        # finish before it is reused; anyone else gets a new matrix.
        image = output === nothing ? nothing : output[]
        if !(image isa Matrix{RGB{N0f8}}) || size(image) != dims
            image = Matrix{RGB{N0f8}}(undef, dims)
            output === nothing || (output[] = image)
        end
    elseif mode === :gray
        out = array!(s, :gray, Gray{N0f8}, dims)
        run!(g -> GF.grayscale!(g, out, src), s, (:gray, dims))
        image = Matrix{Gray{N0f8}}(undef, dims)
    elseif mode === :bw
        out = array!(s, :bw, Gray{Bool}, dims)
        tmp = ntuple(i -> array!(s, (:sauvola, i), Float32, dims), 3)
        run!(g -> GF.sauvola!(g, out, src, window, k, range, tmp), s, (:bw, dims))
        image = Matrix{Gray{Bool}}(undef, dims)
    else
        throw(ArgumentError("mode must be :color, :gray or :bw, not $(repr(mode))"))
    end
    copyto!(image, out)
    return image
end
