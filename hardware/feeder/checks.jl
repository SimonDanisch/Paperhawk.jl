# Checks of the construction before anything is printed: parts that overlap where they should
# not, and springs, motors and shafts against the loads the simulation found.

"Solids of every item built into the current Gmsh model, keyed by item index."
function build_all!(list::Vector{<:Item}; loaded = true)
    tags = Vector{Vector{Tuple{Int32, Int32}}}(undef, length(list))
    for (k, it) in enumerate(list)
        tags[k] = it.build(loaded)
    end
    occ().synchronize()
    return tags
end

function bounding_box(tags)
    lo, hi = fill(Inf, 3), fill(-Inf, 3)
    for (dim, tag) in tags
        b = occ().getBoundingBox(dim, tag)
        lo .= min.(lo, b[1:3])
        hi .= max.(hi, b[4:6])
    end
    return lo, hi
end

overlaps((lo1, hi1), (lo2, hi2); margin = 0.0) = all(lo1 .- margin .<= hi2) && all(lo2 .- margin .<= hi1)

"The items that stand in the assembled feeder: without spare variants."
assembled(d::FeederDesign, b::Build) = filter(it -> it.group != :variants, items(d, b))

"""
    interference(design, build; loaded = true, tolerance = 0.5)

Builds the whole feeder and intersects every pair of items whose bounding boxes touch.
Returns the pairs that share more than `tolerance` mm³, largest first: in a design that fits,
only intended press fits (wedges, O-rings in their grooves) show up.
"""
function interference(d::FeederDesign = FeederDesign(), b::Build = Build(); loaded = true, tolerance = 0.5)
    list = assembled(d, b)
    hits = NamedTuple{(:a, :b, :volume), Tuple{String, String, Float64}}[]
    with_gmsh() do
        gmsh.model.add("interference")
        tags = build_all!(list; loaded)
        boxes = [bounding_box(t) for t in tags]
        for i in eachindex(list), j in (i + 1):length(list)
            overlaps(boxes[i], boxes[j]) || continue
            # Intersect copies: when one solid lies inside the other, OCC hands back the original.
            common, _ = occ().intersect(occ().copy(tags[i]), occ().copy(tags[j]))
            isempty(common) && continue
            v = sum(occ().getMass(dim, tag) for (dim, tag) in common if dim == 3; init = 0.0)
            occ().remove(common, true)
            v > tolerance && push!(hits, (a = list[i].name, b = list[j].name, volume = v))
        end
    end
    return sort!(hits; by = h -> -h.volume)
end

"""
    electronics_check(d, b; tolerance = 0.01)

The bought boards and the room they need (`board_envelopes`: their parts, the motor plugs, the
jumper wires and their bends, the USB-C plug and cable) against every printed part, for each
board at its smallest and its largest, pushed into every corner of its pocket. Returns the
volume each pair shares, mm³; empty when everything is clear.
"""
function electronics_check(d::FeederDesign = FeederDesign(), b::Build = Build(); tolerance = 0.01)
    l = Layout(d, b)
    hits = NamedTuple{(:board, :size, :at, :part, :what, :volume), Tuple{String, Tuple{Float64, Float64}, Vec2d, String, Symbol, Float64}}[]
    with_gmsh() do
        gmsh.model.add("electronics")
        solids = build_named!(items(d, b); keep = printed)
        boxes = Dict(n => bounding_box(t) for (n, t) in solids)
        for bd in BOARDS
            f = board_frame(d, l, bd)
            for s in ((bd.size[1] - bd.spread[1], bd.size[2] - bd.spread[2]), (bd.size[1] + bd.spread[1], bd.size[2] + bd.spread[2]))
                for kx in (-1, 1), ky in (-1, 1)
                    at = Vec2d(kx * (f.hx - s[1] / 2), ky * (f.hy - s[2] / 2))
                    for (what, tags) in ((:room, board_envelopes(d, l, bd; size = s, at)), (:board, board!(d, l, bd; size = s, at)))
                        box = bounding_box(tags)
                        for (name, t) in solids
                            overlaps(box, boxes[name]) || continue
                            v = shared(tags, t)
                            v > tolerance && push!(hits, (board = bd.name, size = s, at = at, part = name, what = what, volume = v))
                        end
                        occ().remove(tags, true)
                    end
                end
            end
        end
    end
    return hits
end

"""
    cable_route_check(d, b; radius = 2.0)

Each motor's lead along `cable_routes` as a tube (the five AWG 26 wires bundled, 4 mm thick)
against every part of the feeder and against the circles the gears' teeth sweep (1 mm wider):
the volume shared, mm³. The lead's first 2 mm leave the motor's housing and are left out.
"""
function cable_route_check(d::FeederDesign = FeederDesign(), b::Build = Build(); radius = 2.0, tolerance = 0.01)
    l = Layout(d, b)
    g = l.gearbox
    G = GEAR_PLANES
    hits = NamedTuple{(:motor, :part, :volume), Tuple{String, String, Float64}}[]
    with_gmsh() do
        gmsh.model.add("cables")
        solids = build_named!(items(d, b); keep = it -> !(it.group in (:coupon, :variants)))
        # Teeth with 1 mm to spare, and what swings with the arm wherever it goes.
        span(u0, u1) = (left_x(d, b, u1), u1 - u0)
        swing = swing_points(l.profile, d)
        sweeps = Dict{String, Vector{Tuple{Int32, Int32}}}("pinion teeth" => cylinder_x(g.motor, tip_radius(g.pinion) + 1.0, span(G.pinion...)...),
            "feed gear teeth" => cylinder_x(l.feed, tip_radius(g.feed) + 1.0, span(G.feed, G.feed + 13.5)...),
            "pick gear teeth" => reduce(vcat, [cylinder_x(P, tip_radius(g.pick) + 1.0, span(G.pick, G.pick + 13.5)...) for P in swing]),
            "idler teeth" => reduce(vcat, [cylinder_x(idler_center(g, l.feed, P), tip_radius(g.idler) + 1.0, span(G.idler...)...) for P in swing]),
            "arm" => reduce(vcat, [cylinder_x(q, 9.0, span(G.arm...)...) for P in swing for q in (P, idler_center(g, l.feed, P))]))
        for r in cable_routes(d, b, l)
            pts = r.points
            start = pts[1] + 2.0 * normalize(pts[2] - pts[1])
            path = vcat([start], pts[2:end])
            tube = Tuple{Int32, Int32}[]
            for k in 1:(length(path) - 1)
                a, v = path[k], path[k + 1] - path[k]
                push!(tube, (3, occ().addCylinder(a[1], a[2], a[3], v[1], v[2], v[3], radius)))
                k > 1 && push!(tube, (3, occ().addSphere(a[1], a[2], a[3], radius)))
            end
            for (name, t) in merge(solids, sweeps)
                name == r.board && continue          # the lead ends on its board
                v = shared(tube, t)
                v > tolerance && push!(hits, (motor = r.motor, part = name, volume = v))
            end
            occ().remove(tube, true)
        end
    end
    return hits
end

"Builds `list` (all of it, or the items `keep` accepts) and returns their solids by name."
function build_named!(list; loaded = true, keep = _ -> true)
    out = Dict{String, Vector{Tuple{Int32, Int32}}}()
    for it in list
        keep(it) || continue
        out[it.name] = it.build(loaded)
    end
    return out
end

"Volume shared by solid sets `a` and `b`, in mm³ (computed on copies)."
function shared(a, b)
    common, _ = occ().intersect(occ().copy(a), occ().copy(b))
    v = sum(occ().getMass(dim, tag) for (dim, tag) in common if dim == 3; init = 0.0)
    isempty(common) || occ().remove(common, true)
    return v
end

"Which of `static` (name => solids) the solids `moving` overlap by more than `tolerance` mm³."
function collisions(moving, static; tolerance = 0.5, ignore = String[])
    box = bounding_box(moving)
    hits = Pair{String, Float64}[]
    for (name, tags) in static
        name in ignore && continue
        overlaps(box, bounding_box(tags)) || continue
        v = shared(moving, tags)
        v > tolerance && push!(hits, name => v)
    end
    return hits
end

"Items that swing with the pick arm about the feed shaft."
const SWINGING = r"^(arm_[lr]|pick_shaft|pick_hub|pick_orings|pick_collar_.*|pick_ratchet|pick_cup_gear|idler|idler_shaft|idler_collar)$"

"""
    swing!(tags, name, l, Δθ)

Turns the solids of swinging item `name` with the arm by `Δθ` about the feed shaft. The idler
rolls on the standing feed gear as it goes, so it also turns about its own axis by Δθ·30/18,
and the pick gear and ratchet by −Δθ (the other teeth keep meshing).
"""
function swing!(tags, name, l::Layout, Δθ)
    F = l.feed
    occ().rotate(tags, 0.0, F[1], F[2], 1.0, 0.0, 0.0, Δθ)
    g = l.gearbox
    P = F + rotate(Vec2d(l.pick - F), Δθ)
    I = idler_center(g, F, Point2d(P))
    name == "idler" && occ().rotate(tags, 0.0, I[1], I[2], 1.0, 0.0, 0.0, Δθ * g.feed.teeth / g.idler.teeth)
    name in ("pick_cup_gear",) && occ().rotate(tags, 0.0, P[1], P[2], 1.0, 0.0, 0.0, -Δθ)
    return tags
end

rotate(v::Vec2d, θ) = Vec2d(cos(θ) * v[1] - sin(θ) * v[2], sin(θ) * v[1] + cos(θ) * v[2])

"Angle (rad) the arm turns from the layout's pose to rest on a stack `h` mm thick."
function arm_turn(d::FeederDesign, l::Layout, h)
    F = l.feed
    P = pick_center(l.profile, d, h)
    a(q) = atan(q[2] - F[2], q[1] - F[1])
    return a(P) - a(l.pick)
end

"""
    motion_check(design, build; heights = (0.0, 4.0, 19.0))

Moves what moves and looks for collisions with everything else: the pick arm with all it
carries resting on an empty tray, on a full stack and lifted 15 mm above it for loading; the
lower exit roller at the bottom of its slot. Returns, per pose, the parts hit and the shared
volume.
"""
function motion_check(d::FeederDesign = FeederDesign(), b::Build = Build(); heights = (0.0, d.stack_height, d.stack_height + 15.0))
    l = Layout(d, b)
    list = assembled(d, b)
    idle_parts = r"^(exit_idle_shaft|exit_idler_\d|idler_\d_orings|exit_idle_collar_.*)$"
    results = Pair{String, Vector{Pair{String, Float64}}}[]
    with_gmsh() do
        gmsh.model.add("motion")
        static = build_named!(list; keep = it -> !occursin(SWINGING, it.name))
        arm = [it for it in list if occursin(SWINGING, it.name)]
        for h in heights
            Δθ = arm_turn(d, l, h)
            moving = reduce(vcat, [swing!(it.build(true), it.name, l, Δθ) for it in arm])
            # The pick roller's O-rings rest on the tray when it is empty, the feed shaft runs in the arms' hubs:
            # those contacts are intended.
            ignore = h <= 0 ? ["tray", "feed_shaft"] : ["feed_shaft"]
            push!(results, "pick arm at $(h) mm" => collisions(moving, static; ignore))
            occ().remove(moving, true)
        end
        names = [n for n in keys(static) if occursin(idle_parts, n)]
        moving = reduce(vcat, [occ().copy(static[n]) for n in names])
        occ().translate(moving, 0, 0, -l.lift)
        others = Dict(n => t for (n, t) in static if !(n in names) && !startswith(n, "idler_spring"))
        push!(results, "lower exit roller $(l.lift) mm down" => collisions(moving, others))
    end
    return results
end

"""
    insertion_check(design, build)

Every shaft goes in along x through the plates once the frame stands. Sweeps each shaft from
outside to its place and reports what it would hit on the way: only the parts it is meant to
pass (its own hub and the collars snapped on later) may show up.
"""
function insertion_check(d::FeederDesign = FeederDesign(), b::Build = Build(); reach = 400.0)
    l = Layout(d, b)
    o = d.inner_width / 2 + b.plate
    list = assembled(d, b)
    frame = it -> it.group == :frame || it.name == "pad_spring" || it.name == "pad_pin"
    shafts = (("pick_shaft", l.pick, -1), ("feed_shaft", l.feed, -1), ("exit_drive_shaft", l.exit_up, 1),
              ("exit_idle_shaft", l.exit_low, -1))
    results = Pair{String, Vector{Pair{String, Float64}}}[]
    with_gmsh() do
        gmsh.model.add("insertion")
        static = build_named!(list; keep = frame)
        for (name, c, from) in shafts
            # The swept volume: the shaft's section from far outside to the far plate.
            x0, x1 = from < 0 ? (-reach, o) : (-o, reach)
            swept = shaft!(b, c, x0, x1)
            push!(results, "$name from $(from < 0 ? "left" : "right")" => collisions(swept, static))
            occ().remove(swept, true)
        end
    end
    return results
end

"Smallest distance between the solids `a` and `b` (mm); 0 where they touch or overlap."
solid_distance(a, b) = minimum(occ().getDistance(i..., j...)[1] for i in a for j in b if i[1] == 3 && j[1] == 3)

"""
    box_window(box, other, u, L)

The stretch of a move along `u` (from `L` before its place to its place) during which the
moving bounding box `box` (taken at the place) meets `other`: `(near, far)`, or `nothing`.
"""
function box_window((lo, hi), (olo, ohi), u, L)
    near, far = 0.0, L
    for k in 1:3
        # lo + t u ≤ ohi and olo ≤ hi + t u, for t in [0, L]
        if abs(u[k]) < 1.0e-12
            (lo[k] <= ohi[k] && olo[k] <= hi[k]) || return nothing
        else
            a, c = (ohi[k] - lo[k]) / u[k], (olo[k] - hi[k]) / u[k]
            near, far = max(near, min(a, c)), min(far, max(a, c))
        end
    end
    return near <= far ? (near, far) : nothing
end

"""
    sequence_check(design, build; plan = assembly_steps(design, build), steps = all, step = 1.5, tolerance = 0.5)

Builds the feeder in the order of the assembly guide (or another `plan`) and makes every move
its steps name (`AssemblyStep.moves`): the items of a move come in along their way, from where
it starts to their place, against everything already in place (earlier steps, the step's base
items and the moves before it in the same step). Against each item in place the move is
followed over the stretch where their bounding boxes meet, at most `step` mm at a time; where
the two are farther apart than that it jumps ahead by their distance, which cannot hide a
contact. A press fit overlaps its mate at its place; on the way it must never overlap more
than there. Returns, per move, each item it hits with the largest overlap beyond the one at its
place (mm³) and the distances before its place between which that happens (mm).
"""
function sequence_check(d::FeederDesign = FeederDesign(), b::Build = Build(); plan = assembly_steps(d, b), steps = nothing, step = 1.5,
        tolerance = 0.5)
    list = assembled(d, b)
    done = Set{String}()
    results = Pair{String, Vector{@NamedTuple{with::String, excess::Float64, from::Float64, to::Float64}}}[]
    with_gmsh() do
        for (k, s) in enumerate(plan)
            if isnothing(steps) || k in steps
                gmsh.model.add("sequence_$k")
                placed = build_named!(list; keep = it -> (!s.apart && it.name in done) || occursin(s.base, it.name))
                for (pattern, way) in s.moves
                    group = [it for it in list if occursin(pattern, it.name) && !haskey(placed, it.name)]
                    isempty(group) && continue
                    solids = [it.build(true) for it in group]
                    moving = reduce(vcat, solids)
                    box = bounding_box(moving)
                    L, u = norm(way), normalize(Vec3d(way))
                    found = @NamedTuple{with::String, excess::Float64, from::Float64, to::Float64}[]
                    for (n, tags) in placed
                        window = box_window(box, bounding_box(tags), u, L)
                        isnothing(window) && continue
                        at_place = overlaps(box, bounding_box(tags)) ? shared(moving, tags) : 0.0
                        worst, farthest, nearest = 0.0, 0.0, Inf
                        position, t = 0.0, last(window)
                        while true
                            occ().translate(moving, ((t - position) * u)...)
                            position = t
                            distance = solid_distance(moving, tags)
                            if distance <= 1.0e-6
                                excess = shared(moving, tags) - at_place
                                if excess > tolerance
                                    worst, farthest, nearest = max(worst, excess), max(farthest, t), min(nearest, t)
                                end
                            end
                            t == first(window) && break
                            t = max(first(window), t - max(distance, step))
                        end
                        occ().translate(moving, (-position * u)...)
                        worst > 0 && push!(found, (with = n, excess = round(worst; digits = 1), from = round(farthest; digits = 1),
                            to = round(nearest; digits = 1)))
                    end
                    for (it, tags) in zip(group, solids)
                        placed[it.name] = tags
                    end
                    push!(results, "$k. $(s.title): $(join(getfield.(group, :name), ", "))" => sort!(found; by = h -> -h.excess))
                    @info "sequence_check" last(results)
                end
                gmsh.model.remove()
            end
            s.kept && union!(done, [it.name for it in list if first(step_role(s, it.name)) != :none])
        end
    end
    return results
end

"Mass (g) and center of mass (mm) of solids, at density `ρ` g/mm³."
function mass_center(tags; ρ = 1.24e-3)
    m, c = 0.0, zeros(3)
    for (dim, tag) in tags
        dim == 3 || continue
        v = occ().getMass(dim, tag)
        m += ρ * v
        c .+= ρ * v .* occ().getCenterOfMass(dim, tag)
    end
    return m, Vec3d(c ./ m)
end

"Densities (g/mm³): printed solid, and the O-rings' NBR."
density(it::Item) = it.material == :PETG ? 1.27e-3 : it.material == :PLA ? 1.24e-3 : 1.0e-3

"""
    pick_force(design, build; heights)

Force (N) with which the pick arm's weight presses the pick roller onto stacks `heights` mm
thick: the moment of everything that swings (all printed solid) about the feed shaft over the
lever of the roller's contact force along the tray normal.
"""
function pick_force(d::FeederDesign = FeederDesign(), b::Build = Build(); heights = (0.0, d.stack_height / 2, d.stack_height), g = 9.81)
    l = Layout(d, b)
    p = l.profile
    F = l.feed
    arm = filter(it -> occursin(SWINGING, it.name), assembled(d, b))
    with_gmsh() do
        gmsh.model.add("pick")
        map(heights) do h
            Δθ = arm_turn(d, l, h)
            m, mc = 0.0, zeros(3)
            for it in arm
                tags = swing!(it.build(true), it.name, l, Δθ)
                mi, ci = mass_center(tags; ρ = density(it))
                m += mi
                mc .+= mi .* ci
                occ().remove(tags, true)
            end
            c = mc ./ m
            τ = -m * 1.0e-3 * g * (c[2] - F[1])                       # N·mm about +x, gravity along -z
            P = pick_center(p, d, h)
            contact = P - d.pick_radius * p.normal
            r = contact - F
            lever = r[1] * p.normal[2] - r[2] * p.normal[1]           # torque per N the stack pushes back
            (height = h, mass = round(m; digits = 1), force = round(-τ / lever; digits = 3))
        end
    end
end

"Second moment of area (mm⁴) of a polygon about its centroidal axis along `axis`."
function second_moment(pts::Vector{Point2d}, axis::Vec2d)
    n = length(pts)
    A = sum(cross(pts[i], pts[mod1(i + 1, n)]) for i in 1:n) / 2
    C = sum((pts[i] + pts[mod1(i + 1, n)]) * cross(pts[i], pts[mod1(i + 1, n)]) for i in 1:n) / (6A)
    q = [Vec2d(x - C) for x in pts]
    u = normalize(axis)
    v = Vec2d(-u[2], u[1])                                      # distance measured along v
    h = [dot(x, v) for x in q]
    I = sum((h[i]^2 + h[i] * h[mod1(i + 1, n)] + h[mod1(i + 1, n)]^2) * cross(q[i], q[mod1(i + 1, n)]) for i in 1:n) / 12
    return abs(I), maximum(abs, h)
end

"""
    strength_report(design, build, settings; peaks)

Beam-theory checks of the printed parts against the loads the simulation found: shaft bending,
spring stresses, pawl strain and buckling, and the motors' reserve. `peaks` holds the largest
motor forces (N at the roller surface) from the simulation sweeps. Each row gives the value,
the limit it is held against and the ratio.
"""
function strength_report(d::FeederDesign = FeederDesign(), b::Build = Build(), s::FeedSettings = FeedSettings();
        peaks = (drive = 2.55, exit = 1.93), weak = 0.7, torque = 37.3)
    rows = NamedTuple{(:check, :value, :limit, :unit, :ratio), Tuple{String, Float64, Float64, String, Float64}}[]
    row!(check, value, limit, unit) = push!(rows, (; check, value = round(value; sigdigits = 3), limit, unit,
        ratio = round(value / limit; digits = 2)))
    E_pla, E_petg = 2680.0, 1460.0
    I, c = second_moment(d_outline(Point2d(0, 0), b.shaft, b.flat, Vec2d(0, -1)), Vec2d(1, 0))
    span = d.inner_width + b.plate                              # bearing to bearing
    # Feed shaft: the pad presses at the middle. The pad spring follows the sag and presses that
    # much less (F / (1 + k C)); 0.3 mm keeps the pad force inside the simulated range.
    C = span^3 / (48 * E_pla * I)                               # mm per N
    F = s.pad_force / (1 + s.pad_rate * 1.0e-3 * C)
    row!("feed shaft sag under the pad", F * C, 0.3, "mm")
    row!("feed shaft bending stress", F * span / 4 * c / I, 7.0, "MPa")
    # Pick shaft: carried by the two arms outside the plates; at its middle the stack pushes the
    # roller back with the arm's weight and, at most, the tires' grip on top. Its sag tilts nothing:
    # the roller sits in the middle, and the arm's weight sets the force however the shaft bends.
    arms = span + 2 * GEAR_PLANES.arm[2]
    Fp = s.pick_weight * hypot(1.0, s.rubber.static)
    row!("pick shaft bending stress", Fp * arms / 4 * c / I, 7.0, "MPa")
    # Exit shafts: the idler springs' force through two rollers at ±55 mm bends both shafts apart.
    # The springs keep the nip closed whatever the sag; what matters is that each roller stays
    # parallel to its partner, so the O-rings stay squeezed across the roller's width.
    a = span / 2 - b.exit_rollers[2]
    P = s.idler_force / 2
    θ = P * a * (span - 2a) / (2 * E_pla * I)                  # slope at the rollers
    row!("exit rollers out of parallel across their width", 2θ * b.exit_roller_length, 0.3, "mm")
    row!("exit shaft bending stress", P * a * c / I, 7.0, "MPa")
    # Springs (PETG): stress at the working deflection, held against creep.
    for (name, leaf, force) in (("pad spring", PAD_LEAF, 2.0), ("idler spring", IDLER_LEAF, s.idler_force / 2))
        δ = deflection(leaf, force)
        row!("$name stress at $(force) N", stress(leaf, δ), 10.0, "MPa")
        row!("$name deflection at $(force) N", δ, 8.0, "mm")
    end
    # Pawls: bending strain over a 1 mm tooth and buckling under the motor torque.
    t, h, tooth = PAWL, 7.0, 1.0
    φ = deg2rad(15.0)
    len = pawl_length(Vec2d(8.85, 0.0), Vec2d(sin(φ), -cos(φ)), 17.5)
    row!("pawl strain over a tooth", 3 * t * tooth / (2 * len^2) * 100, 3.0, "%")
    Ipawl = h * t^3 / 12
    pawls = 1
    l = Layout(d, b)
    g = l.gearbox
    # The cup gears have more teeth than the pinion: a blocked roller gets that much more torque.
    row!("pawl load vs Euler buckling", torque * g.pick.teeth / g.pinion.teeth / 9.0 / pawls, π^2 * E_petg * Ipawl / (2len)^2, "N")
    # Overrunning drag: the pawl rides up a 13° ramp with half its full spring force on average,
    # with PETG on PLA friction, at the ratchet's 9 mm, felt at the 12 mm roller.
    ramp = atan(tooth / (0.9 * 2π * 9.0 / 12))
    F = 3 * E_petg * Ipawl / len^3 * tooth / 2
    drag = pawls * F * (0.3 + tan(ramp)) * 9.0 / d.feed_radius
    row!("freewheel drag at the roller vs simulated", drag, s.freewheel_drag, "N")
    # Gears: Lewis bending stress of the pinion's teeth (the smallest gear with the motor's full
    # torque) over the width it meshes, of the idler's teeth where they mesh the feed gear (all
    # of it going on to the pick roller), and how many teeth share the load (contact ratio, with
    # the printed play).
    G = GEAR_PLANES
    Ft = torque / pitch_radius(g.pinion)                        # N at the pinion's and the cup gears' pitch circles
    row!("pinion tooth bending stress at full motor torque", Ft / (13.5 * g.pinion.m * 0.32), 10.0, "MPa")   # Lewis Y, 20 teeth
    row!("idler tooth bending stress at full motor torque", Ft / ((G.idler[2] - G.feed) * g.idler.m * 0.31), 10.0, "MPa")   # 18 teeth
    for (name, a, other) in (("pinion to feed gear", g.pinion, g.feed), ("feed gear to idler", g.feed, g.idler), ("idler to pick gear", g.idler, g.pick))
        row!("contact ratio $name, at least 1.2", contact_ratio(a, other), 1.2, "")
    end
    row!("pick gear to feed shaft clearance, at least 0.5", norm(Vec2d(l.pick - l.feed)) - tip_radius(g.pick) - b.shaft / 2, 0.5, "mm")
    # Motors: largest force the simulation asked for of a motor 30 % weaker than a 28BYJ-48 at
    # 9.75 rpm (333 full steps/s), where 380 gf·cm = 37.3 mN·m was measured (jangeox.be); the
    # drive motor's through the 20:30 gears.
    row!("drive motor force at pick and feed roller", peaks.drive, weak * torque * s.reduction / d.feed_radius, "N")
    row!("exit motor force", peaks.exit, weak * torque / d.exit_radius, "N")
    return rows
end

"""
    contact_ratio(a, b; play = 0.15)

How many tooth pairs carry the load on average when gears `a` and `b` mesh `play` mm further
apart than their pitch circles touch (the printed play): above 1 the next pair takes over
before the last lets go.
"""
function contact_ratio(a::Gear, b::Gear; play = 0.15)
    α = deg2rad(a.pressure)
    C0 = pitch_radius(a) + pitch_radius(b)
    C = C0 + play
    αw = acos(C0 * cos(α) / C)
    rb(g) = pitch_radius(g) * cos(α)
    path = sqrt(tip_radius(a)^2 - rb(a)^2) + sqrt(tip_radius(b)^2 - rb(b)^2) - C * sin(αw)
    return path / (π * a.m * cos(α))
end

"""
    camera_check(design, build; piles = (0.0, 15.0))

Whether any part of the feeder hides part of the sheet from the phone. Every surface point of
every item is projected from the camera (the phone's center, `camera_height` above the box
floor over the box's middle) onto the sheet lying in the box, for an empty box and one
holding `pile` mm of paper. Returns, per pile height, the items whose shadow falls on the
sheet's area (x within the sheet's width, y over the box's length), how many points do and
the y range their shadow covers.
"""
function camera_check(d::FeederDesign = FeederDesign(), b::Build = Build(); piles = (0.0, 15.0))
    camera = Vec3d(0.0, d.box_length / 2, d.camera_height)
    list = filter(it -> it.name != "phone", assembled(d, b))
    hidden = Dict{Float64, Vector{NamedTuple{(:item, :points, :ys), Tuple{String, Int, NTuple{2, Float64}}}}}(z => [] for z in piles)
    with_gmsh() do
        for it in list
            gmsh.model.add(it.name)
            it.build(true)
            occ().synchronize()
            gmsh.option.setNumber("Mesh.MeshSizeMax", 4.0)
            gmsh.model.mesh.generate(2)
            _, coords, _ = gmsh.model.mesh.getNodes()
            gmsh.model.remove()
            pts = [Vec3d(coords[3i - 2], coords[3i - 1], coords[3i]) for i in 1:(length(coords) ÷ 3)]
            for z in piles
                shadow = Float64[]
                for q in pts
                    (q[3] > z + 0.5 && q[3] < camera[3]) || continue
                    s = camera + (camera[3] - z) / (camera[3] - q[3]) * (q - camera)
                    abs(s[1]) <= d.sheet_width / 2 && 0.0 <= s[2] <= d.box_length && push!(shadow, s[2])
                end
                isempty(shadow) || push!(hidden[z], (item = it.name, points = length(shadow), ys = extrema(shadow)))
            end
        end
    end
    return hidden
end
