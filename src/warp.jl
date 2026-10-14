# Warping the sheet flat: the projective map that takes the corners of the
# output to the corners found in the frame, applied to every output pixel.

"""
    homography(from, to) -> Mat{3, 3, Float64}

The projective map `H` with `H * (from[k]..., 1) ∝ (to[k]..., 1)` for the four
point pairs.
"""
function homography(from::NTuple{4, <:Vec{2}}, to::NTuple{4, <:Vec{2}})
    A = zeros(8, 8)
    rhs = zeros(8)
    for k in 1:4
        x, y = Float64.(from[k])
        u, v = Float64.(to[k])
        A[2k - 1, :] = [x, y, 1, 0, 0, 0, -u * x, -u * y]
        A[2k, :] = [0, 0, 0, x, y, 1, -v * x, -v * y]
        rhs[2k - 1], rhs[2k] = u, v
    end
    h = A \ rhs
    # Mat is filled column by column.
    return Mat{3, 3, Float64}(h[1], h[4], h[7], h[2], h[5], h[8], h[3], h[6], 1.0)
end

function project(H::Mat{3, 3, Float64}, p::Vec{2})
    q = H * Vec3(Float64(p[1]), Float64(p[2]), 1.0)
    return Vec2f(q[1] / q[3], q[2] / q[3])
end

"""
    paper_size(paper = :a4; dpi = 300) -> (width, height)

The size in pixels of a sheet held upright.
"""
function paper_size(paper::Symbol = :a4; dpi = 300)
    mm = Dict(:a4 => (210, 297), :a5 => (148, 210), :letter => (215.9, 279.4))[paper]
    return round.(Int, mm ./ 25.4 .* dpi)
end

"""
    portrait(corners) -> corners

The same quadrilateral, starting at a different corner when the sheet lies on
its side in the frame, so that its long sides end up vertical. Which way up the
text is comes later, from the text itself.
"""
function portrait(corners::NTuple{4, Vec2f})
    tl, tr, br, bl = corners
    wide = norm(tr - tl) + norm(br - bl)
    tall = norm(bl - tl) + norm(br - tr)
    return wide > tall ? (bl, tl, tr, br) : corners
end

"""
    measured_size(corners) -> (width, height)

The sheet's size in pixels of the frame, from the mean lengths of opposite sides.
"""
function measured_size(corners::NTuple{4, Vec2f})
    tl, tr, br, bl = corners
    w = (norm(tr - tl) + norm(br - bl)) / 2
    h = (norm(bl - tl) + norm(br - tr)) / 2
    return round(Int, w), round(Int, h)
end

"""
    page_size(corners, paper = :a4; dpi = 300) -> (width, height)

The size in pixels of the flat page: `paper`'s at `dpi`, or with `paper = :auto`
the sheet's own proportions at the frame's resolution, for things that are not
A4.
"""
page_size(corners::NTuple{4, Vec2f}, paper::Symbol = :a4; dpi = 300) =
    paper === :auto ? measured_size(portrait(corners)) : paper_size(paper; dpi)
