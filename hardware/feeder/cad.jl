# The paper path's profile pieces as solids: chains of lines and arcs offset into guides and
# extruded across x with Gmsh's OpenCASCADE kernel (PrintSim's `prism`, `extrude_loop`). All in
# millimeters; the side profile (y, z) is extruded across x, x = 0 is the middle of the sheet.

start_point(l::Line) = l.a
end_point(l::Line) = l.b
start_point(a::Arc) = a.center + a.radius * Vec2d(cos(a.start), sin(a.start))
end_point(a::Arc) = a.center + a.radius * Vec2d(cos(a.stop), sin(a.stop))

"The piece moved sideways by `t`, to the right of its direction of travel (negative: left)."
function offset(l::Line, t)
    u = normalize(l.b - l.a)
    r = Vec2d(u[2], -u[1])
    return Line(l.a + t * r, l.b + t * r)
end
offset(a::Arc, t) = Arc(a.center, a.radius + t, a.start, a.stop, a.inside)   # counterclockwise: right is outward

"Where the infinite lines through `a` and `b` cross."
function intersection(a::Line, b::Line)
    u, v = a.b - a.a, b.b - b.a
    s = cross(b.a - a.a, v) / cross(u, v)
    return a.a + s * u
end

"""
Whether each piece of a chain runs from its start to its end along the chain: arcs always go
counterclockwise from `start` to `stop`, so a chain may run through one backward.
"""
function directions(pieces::Vector)
    length(pieces) == 1 && return [true]
    second = (start_point(pieces[2]), end_point(pieces[2]))
    near(q) = minimum(norm(q - s) for s in second)
    fwd = [near(end_point(pieces[1])) <= near(start_point(pieces[1]))]
    last_point = fwd[1] ? end_point(pieces[1]) : start_point(pieces[1])
    for piece in pieces[2:end]
        f = norm(start_point(piece) - last_point) <= norm(end_point(piece) - last_point)
        push!(fwd, f)
        last_point = f ? end_point(piece) : start_point(piece)
    end
    return fwd
end

"Where a chain of pieces begins and ends."
chain_start(pieces::Vector) = directions(pieces)[1] ? start_point(first(pieces)) : end_point(first(pieces))
chain_end(pieces::Vector) = directions(pieces)[end] ? end_point(last(pieces)) : start_point(last(pieces))

"""
All pieces moved sideways by `t`, to the right of the chain's direction of travel. Where two
straight pieces meet at a corner, their offsets are trimmed or extended to meet (a miter);
tangent joins meet by themselves, and a straight piece bridges any other corner.
"""
function offset(pieces::Vector, t)
    fwd = directions(pieces)
    moved = Union{Line, Arc}[offset(p, f ? t : -t) for (p, f) in zip(pieces, fwd)]
    for i in 1:(length(moved) - 1)
        a, b = moved[i], moved[i + 1]
        (a isa Line && b isa Line) || continue
        abs(cross(normalize(a.b - a.a), normalize(b.b - b.a))) < 1.0e-9 && continue
        x = intersection(a, b)
        moved[i], moved[i + 1] = Line(a.a, x), Line(x, b.b)
    end
    # Other corners: both pieces trimmed or extended to where they cross next to the corner, or
    # bridged by a straight piece if they do not.
    for i in 1:(length(moved) - 1)
        a, b = moved[i], moved[i + 1]
        a isa Line && b isa Line && continue
        stop = fwd[i] ? end_point(a) : start_point(a)
        start = fwd[i + 1] ? start_point(b) : end_point(b)
        norm(start - stop) < 1.0e-6 && continue
        x = crossing(a, b, (stop + start) / 2)
        (x === nothing || norm(x - stop) > 4 * abs(t) + 1.0) && continue
        moved[i] = with_end(a, x, fwd[i] ? :stop : :start)
        moved[i + 1] = with_end(b, x, fwd[i + 1] ? :start : :stop)
    end
    out = Union{Line, Arc}[moved[1]]
    for i in 2:length(moved)
        stop = fwd[i - 1] ? end_point(moved[i - 1]) : start_point(moved[i - 1])
        start = fwd[i] ? start_point(moved[i]) : end_point(moved[i])
        norm(start - stop) > 1.0e-6 && push!(out, Line(stop, start))
        push!(out, moved[i])
    end
    return out
end

"The point where a line and a circle (the pieces taken whole) cross nearest to `near`, or nothing."
crossing(a::Arc, b::Line, near) = crossing(b, a, near)
function crossing(l::Line, a::Arc, near)
    u = normalize(l.b - l.a)
    w = l.a - a.center
    β = dot(u, w)
    disc = β^2 - dot(w, w) + a.radius^2
    disc < 0 && return nothing
    return argmin(q -> norm(q - near), [l.a + (-β + σ * sqrt(disc)) * u for σ in (-1, 1)])
end
crossing(a::Arc, b::Arc, near) = nothing

"The piece with its `start` or `stop` end moved to `x`."
with_end(l::Line, x, at) = at == :start ? Line(x, l.b) : Line(l.a, x)
function with_end(a::Arc, x, at)
    φ = atan(x[2] - a.center[2], x[1] - a.center[1])
    # Keep the angle on the same turn as the end it replaces.
    old = at == :start ? a.start : a.stop
    φ += 2π * round((old - φ) / 2π)
    return at == :start ? Arc(a.center, a.radius, φ, a.stop, a.inside) : Arc(a.center, a.radius, a.start, φ, a.inside)
end

"A piece made longer by `e` at its start (`at = :start`) or its end (`at = :stop`)."
function lengthen(l::Line, e, at)
    u = normalize(l.b - l.a)
    return at == :start ? Line(l.a - e * u, l.b) : Line(l.a, l.b + e * u)
end
lengthen(a::Arc, e, at) = at == :start ? Arc(a.center, a.radius, a.start - e / a.radius, a.stop, a.inside) :
    Arc(a.center, a.radius, a.start, a.stop + e / a.radius, a.inside)

"Pieces of a path made longer by `e` at both open ends."
function extend(pieces::Vector, e)
    e == 0 && return pieces
    fwd = directions(pieces)
    out = Union{Line, Arc}[pieces...]
    out[1] = lengthen(out[1], e, fwd[1] ? :start : :stop)
    out[end] = lengthen(out[end], e, fwd[end] ? :stop : :start)
    return out
end

curve(pts, l::Line, forward) = forward ? occ().addLine(pts[l.a], pts[l.b]) : occ().addLine(pts[l.b], pts[l.a])
function curve(pts, a::Arc, forward)
    s, e = pts[start_point(a)], pts[end_point(a)]
    c = pts[a.center]
    return forward ? occ().addCircleArc(s, c, e) : occ().addCircleArc(e, c, s)
end

"""
A guide of `thickness` along the profile pieces, material on the right of the direction of
travel for `side = 1` and on the left for `side = -1`, extruded across x.
"""
function guide_solid(pieces, thickness, side, x0, width)
    pts = PointCache(x0)
    fwd = directions(pieces)
    outer = offset(pieces, side * thickness)
    curves = Int32[]
    append!(curves, [curve(pts, p, f) for (p, f) in zip(pieces, fwd)])
    push!(curves, occ().addLine(pts[chain_end(pieces)], pts[chain_end(outer)]))
    append!(curves, [curve(pts, p, !f) for (p, f) in zip(reverse(outer), reverse(directions(outer)))])
    push!(curves, occ().addLine(pts[chain_start(outer)], pts[chain_start(pieces)]))
    return extrude_loop(curves, width)
end

