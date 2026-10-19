# Checks on the parts as printed. Nearly everything in the feeder is a profile across x, so
# every check cuts the printed parts at planes of constant x and works in the profile plane:
# a shaft turned through a full circle in its printed bore, the pinion rolled against both cup
# gears, the ratchet turned under its pawl, pegs and feet checked for material around them.

"A region turned by `θ` about `c` in the profile plane."
function turned(g, c::Point2d, θ)
    s, k = sincos(θ)
    return map_region(g, v -> [c[1] + k * (v[1] - c[1]) - s * (v[2] - c[2]), c[2] + s * (v[1] - c[1]) + k * (v[2] - c[2])])
end

overlap(a, b) = GEOS.area(GEOS.intersection(a, b))
gap(a, b) = GEOS.distance(a, b)

"Cross section of a 28BYJ-48's shaft (bought, as drawn): 5 mm round with flats 3 mm apart."
function motor_shaft_section(c::Point2d; n = 48)
    r, f = BYJ48.shaft / 2, BYJ48.flats / 2
    pts = [c + r * Vec2d(cos(φ), sin(φ)) for φ in range(0, 2π; length = n + 1)[1:n]]
    pts = [Point2d(q[1], clamp(q[2], c[2] - f, c[2] + f)) for q in pts]
    return GEOS.Polygon([[[q[1], q[2]] for q in vcat(pts, pts[1:1])]])
end

"""
A bought part where it meets a printed one, as its drawing gives it: `region(x, axis)` is its
cross section at `x` in the profile plane. It does not shrink or drift.
"""
struct BoughtSection{F}
    name::String
    region::F
end

"The motor shaft's flattened part, and its round part next to the motor (Ø5, up to 4.7 mm out)."
const MOTOR_SHAFT = BoughtSection("motor shaft", (x, axis) -> motor_shaft_section(axis))
const MOTOR_SHAFT_ROUND = BoughtSection("motor shaft, round part", (x, axis) -> disk(axis, BYJ48.shaft / 2))

"""
A place where two parts meet, cut at the planes `xs`. Both parts are lined up where they meet:
at `axis`, or without one at the middle of the moving part's cut. `kind` says what it has to do:

- `:turns`: `moving` turns about `axis` in `host` and must not touch it at any angle;
- `:holds`: a clamp or press fit, `moving` must overlap `host` a little;
- `:slides`: `moving` goes into `host` and must not overlap it;
- `:sits`: a peg or pin, `moving` needs `host` material all around it;
- `:rests`: a foot or block on a face, `moving` (cut at `xs`) needs `host` (cut at `host_xs`)
  under all of it.
"""
struct Joint
    name::String
    moving::Union{String, BoughtSection}
    host::Union{String, BoughtSection}
    kind::Symbol
    axis::Union{Point2d, Nothing}
    xs::Vector{Float64}
    host_xs::Vector{Float64}
    only::Union{Vector{Point2d}, Nothing}   # the part of the moving section that counts, if not all of it
end
Joint(name, moving, host, kind, axis, xs; only = nothing) = Joint(name, moving, host, kind, axis, xs, xs, only)
Joint(name, moving, host, kind, axis, xs, host_xs) = Joint(name, moving, host, kind, axis, xs, host_xs, nothing)

"""
    joints(d, b)

Every place where printed parts meet in the feeder (and the two motor shafts, which are bought),
with the planes that cut through them.
"""
function joints(d::FeederDesign, b::Build)
    l = Layout(d, b)
    g = l.gearbox
    G = GEAR_PLANES
    W2, o = d.inner_width / 2, d.inner_width / 2 + b.plate
    inL, inR = [-o + 3.1, -W2 - 2.1], [W2 + 2.1, o - 3.1]           # inside each plate, off its faces
    pocketL, pocketR = [-W2 - 1.1, -W2 - 2.3], [W2 + 1.1, W2 + 2.3]
    js = Joint[]
    J(args...) = push!(js, Joint(args...))
    for (shaft, c) in (("feed_shaft", l.feed), ("exit_drive_shaft", l.exit_up), ("exit_idle_shaft", l.exit_low))
        J("$shaft in left plate", shaft, "side_plate_left", :turns, c, inL)
        J("$shaft in right plate", shaft, "side_plate_right", :turns, c, inR)
    end
    # The pick arm: its hubs turn on the feed shaft, the pick shaft turns in it, the idler's shaft
    # is clamped in the left arm and the idler turns on it.
    armL, armR = [left_x(d, b, G.arm[1] + 1.1), left_x(d, b, G.arm[2] - 1.1)], [o + G.arm[1] + 1.1, o + G.arm[2] - 1.1]
    I = idler_center(g, l.feed, l.pick)
    J("left arm on feed shaft", "arm_l", "feed_shaft", :turns, l.feed, armL)
    J("right arm on feed shaft", "arm_r", "feed_shaft", :turns, l.feed, armR)
    J("pick shaft in left arm", "pick_shaft", "arm_l", :turns, l.pick, armL)
    J("pick shaft in right arm", "pick_shaft", "arm_r", :turns, l.pick, armR)
    J("idler shaft in left arm", "idler_shaft", "arm_l", :holds, I, armL)
    J("idler on its shaft", "idler", "idler_shaft", :turns, I, [left_x(d, b, G.idler[1] + 2.1), left_x(d, b, G.idler[2] - 2.1)])
    # Cup gears turn on their shafts over their base and hub, the last 6.5 mm away from the plate.
    for (name, c, u) in (("feed", l.feed, G.feed), ("pick", l.pick, G.pick))
        J("$name cup gear on $(name) shaft", "$(name)_cup_gear", "$(name)_shaft", :turns, c, [left_x(d, b, u + 7.6), left_x(d, b, u + 12.9)])
    end
    # The motor shaft (10 ± 0.5 mm from the mounting face, flats over the outer 6 ± 0.2 mm) is
    # round up to 4.7 mm out and flat from 3.3 mm out at the most; the sockets are round to 4.9
    # mm and flat beyond, and the 244 mm exit shaft's socket moves up to 0.7 mm farther out as
    # it cools. The flat part holds from 6 to 9 mm out (the shortest shaft ends at 9.5).
    # Planes are given as distance s from the motor's face.
    mface = -(o + G.face)
    J("pinion on motor shaft", "drive_pinion", MOTOR_SHAFT, :holds, g.motor, [mface + 6.0, mface + 7.5, mface + 9.0])
    J("pinion clear of the motor shaft's round part", "drive_pinion", MOTOR_SHAFT_ROUND, :slides, g.motor, [mface + 4.45])
    J("exit shaft socket on motor shaft", "exit_drive_shaft", MOTOR_SHAFT, :holds, l.exit_up, [o - 6.0, o - 7.5, o - 9.0])
    J("exit shaft socket clear of the round part", "exit_drive_shaft", MOTOR_SHAFT_ROUND, :slides, l.exit_up, [o - 2.5, o - 4.5])
    for (hub, shaft, c, xs) in (("pick_hub", "pick_shaft", l.pick, [-10.1, 9.9]), ("feed_hub", "feed_shaft", l.feed, [-10.1, 9.9]),
            ("exit_hub_1", "exit_drive_shaft", l.exit_up, [b.exit_rollers[1] - 4.1, b.exit_rollers[1] + 3.9]),
            ("exit_hub_2", "exit_drive_shaft", l.exit_up, [b.exit_rollers[2] - 4.1, b.exit_rollers[2] + 3.9]),
            ("exit_idler_1", "exit_idle_shaft", l.exit_low, [b.exit_rollers[1] - 4.1, b.exit_rollers[1] + 3.9]),
            ("exit_idler_2", "exit_idle_shaft", l.exit_low, [b.exit_rollers[2] - 4.1, b.exit_rollers[2] + 3.9]),
            ("feed_ratchet", "feed_shaft", l.feed, [left_x(d, b, G.feed + 1.6), left_x(d, b, G.feed + 5.4)]),
            ("pick_ratchet", "pick_shaft", l.pick, [left_x(d, b, G.pick + 1.6), left_x(d, b, G.pick + 5.4)]))
        J("$hub on $shaft", hub, shaft, :holds, c, xs)
    end
    for side in (-1, 1)
        plate = side < 0 ? "side_plate_left" : "side_plate_right"
        s = side < 0 ? "l" : "r"
        J("idler spring $s pegs in plate", "idler_spring_$s", plate, :sits, nothing, side * [o - 2.1, o - 3.9])
        J("idler spring $s block on plate", "idler_spring_$s", plate, :rests, nothing, [side * (o + 0.6)], [side * (o - 0.6)])
        for name in ("tray", "lower_guide_$s", "upper_guide", "electronics_carrier")
            J("$name in $plate pocket", name, plate, :slides, nothing, side < 0 ? pocketL : pocketR)
        end
        for (k, c) in enumerate(l.ties)
            name = k == 1 ? "pad_bar" : "tie_bar_$(k - 1)"
            J("$name tenon in $plate", name, plate, :slides, c, side < 0 ? inL : inR)
        end
    end
    J("bracket pegs in left plate", "drive_bracket", "side_plate_left", :sits, nothing, [-o + 1.1, -o + 3.9])
    J("bracket feet on left plate", "drive_bracket", "side_plate_left", :rests, nothing, [-o - 0.6], [-o + 0.6])
    J("exit lug pins in right plate", "exit_lug_pin_1", "side_plate_right", :sits, l.exit_up, [o - 2.1, o - 4.9])
    J("exit lug pins in right plate", "exit_lug_pin_2", "side_plate_right", :sits, l.exit_up, [o - 2.1, o - 4.9])
    face = -(o + G.face)
    for k in 1:2
        J("drive lug pin $k in bracket", "drive_lug_pin_$k", "drive_bracket", :sits, g.motor, [face + 0.9, face + 2.1])
    end
    # The stand's pegs go into the tray's blind holes; only the pegs count, not the bar the tray rests on.
    p = l.profile
    s = -d.tray_length + TRAY_LEG.at
    peg = [along(p, s - 5, -2.9), along(p, s + 5, -2.9), along(p, s + 5, 0.0), along(p, s - 5, 0.0)]
    for x in TRAY_LEG.pegs
        push!(js, Joint("tray stand peg at x = $x in tray", "tray_leg", "tray", :slides, nothing, [x]; only = peg))
    end
    J("pad pin in pad bar", "pad_pin", "pad_bar", :holds, l.pad_bar, [-0.1])
    return js
end

"Section of a part at `x`: a printed part as printed, a bought part as drawn."
part_section(printed::Dict{String, PrintedPart}, name::String, x, axis::Point2d) = section(printed[name], x)
part_section(::Dict{String, PrintedPart}, p::BoughtSection, x, axis::Point2d) = p.region(x, axis)

"How far cooling moved a part at (`x`, `axis`) in the profile plane; bought parts stay."
function profile_drift(printed::Dict{String, PrintedPart}, name::String, x, axis::Point2d)
    v = drift(printed[name], Vec3d(x, axis[1], axis[2]))
    return Vec2d(v[2], v[3])
end
profile_drift(::Dict{String, PrintedPart}, ::BoughtSection, x, axis::Point2d) = Vec2d(0, 0)

"A region moved by `v` in the profile plane."
moved(g, v::Vec2d) = map_region(g, q -> [q[1] + v[1], q[2] + v[2]])

"""
    check(joint, printed; angles = 0:10:350)

What the printed parts do at `joint`, the worst over its planes: for `:turns` the smallest gap
at any angle (negative: the overlap area in mm² where it binds), for `:holds` the overlap
(positive: it grips) or the gap, for `:slides` the gap, for `:sits` and `:rests` how much of the
moving part has material around or under it.
"""
function check(j::Joint, printed::Dict{String, PrintedPart}; angles = 0:10:350)
    worst = j.kind in (:sits, :rests) ? 1.0 : Inf
    for (x, xh) in zip(j.xs, j.host_xs)
        # The moving part sits where the host's feature ended up after cooling.
        a0 = part_section(printed, j.moving, x, something(j.axis, Point2d(0, 0)))
        j.only === nothing || (a0 = GEOS.intersection(a0, GEOS.Polygon([[[q[1], q[2]] for q in vcat(j.only, j.only[1:1])]])))
        at = something(j.axis, Point2d(GEOS.GeoInterface.coordinates(GEOS.centroid(a0))...))
        dh = profile_drift(printed, j.host, xh, at)
        a = moved(j.axis === nothing ? a0 : part_section(printed, j.moving, x, at), dh - profile_drift(printed, j.moving, x, at))
        h = part_section(printed, j.host, xh, at)
        axis = at + dh
        GEOS.isEmpty(a) && error("$(j.moving) has no material at x = $x ($(j.name))")
        if j.kind == :turns
            for θ in angles
                t = turned(a, axis, deg2rad(θ))
                o = overlap(t, h)
                worst = min(worst, o > 1.0e-4 ? -o : gap(t, h))
            end
        elseif j.kind == :holds
            o = overlap(a, h)
            worst = min(worst, o > 1.0e-4 ? o : -gap(a, h))
        elseif j.kind == :slides
            o = overlap(a, h)
            worst = min(worst, o > 1.0e-4 ? -o : gap(a, h))
        elseif j.kind == :sits
            ring = GEOS.difference(GEOS.buffer(a, 0.6, 8), a)
            worst = min(worst, overlap(ring, h) / GEOS.area(ring))
        else
            # Its own pegs fill the holes under it.
            own = moved(part_section(printed, j.moving, xh, at), dh - profile_drift(printed, j.moving, xh, at))
            worst = min(worst, overlap(a, GEOS.union(h, own)) / GEOS.area(a))
        end
    end
    return worst
end

"""
    joint_report(printed, d, b)

Every joint checked on the printed parts, with a verdict: turning parts need a gap at every
angle, fits that hold need some overlap (clamps, press fits) but not more than printed parts
give (0.3 mm² per mm of contact is a hard press), slides need a gap, pegs and feet need
material around or under at least 80 % of them.
"""
function joint_report(printed::Dict{String, PrintedPart}, d::FeederDesign = FeederDesign(), b::Build = Build())
    map(joints(d, b)) do j
        v = check(j, printed)
        ok = j.kind == :turns ? v > 0.02 : j.kind == :holds ? v > 0 : j.kind == :slides ? v >= 0 : v >= 0.8
        (joint = j.name, kind = j.kind, value = round(v; digits = 3), ok = ok)
    end
end

"Smallest and largest distance from `c` of the outline of a region."
function radii(g, c::Point2d)
    rs = Float64[]
    for poly in polygons(g), v in GEOS.GeoInterface.coordinates(GEOS.exteriorRing(poly))
        push!(rs, hypot(v[1] - c[1], v[2] - c[2]))
    end
    return extrema(rs)
end

disk(c::Point2d, r) = GEOS.buffer(GEOS.Point(c[1], c[2]), r, 32)

"""
    mesh_check(printed, d, b; steps = 24)

The printed gears rolled against each other over one tooth pitch, in two planes of each pair:
the pinion against the feed gear, the feed gear against the arm's idler, the idler against the
pick gear, about the axes where the cooled parts hold them (the plate the bracket and the feed
shaft sit in, the arm the idler and pick shafts sit in). Whether the teeth ever overlap (they
jam), and the backlash, from turning the driven gear each way against the held driver until
the teeth touch (mm at the driven gear's pitch circle).
"""
function mesh_check(printed::Dict{String, PrintedPart}, d::FeederDesign = FeederDesign(), b::Build = Build(); steps = 24)
    l = Layout(d, b)
    g = l.gearbox
    G = GEAR_PLANES
    rows = []
    plate, arm = printed["side_plate_left"], printed["arm_l"]
    o = d.inner_width / 2 + b.plate
    F, P = l.feed, l.pick
    I = idler_center(g, F, P)
    # The feed axis sits where the cooled plate holds it; the motor on the bracket pegged into the
    # same plate; the idler and pick axes where the cooled arm holds them about the feed axis.
    on(part, x, q::Point2d) = (v = drift(part, Vec3d(x, q[1], q[2])); q + Vec2d(v[2], v[3]))
    xp, xa = -o + 4.0, left_x(d, b, sum(G.arm) / 2)
    Fp = on(plate, xp, F)
    shift = Vec2d(Fp - on(arm, xa, F))
    axes = Dict("drive_pinion" => on(plate, xp, g.motor), "feed_cup_gear" => Fp,
        "idler" => on(arm, xa, I) + shift, "pick_cup_gear" => on(arm, xa, P) + shift)
    design = Dict("drive_pinion" => (g.motor, g.pinion), "feed_cup_gear" => (F, g.feed), "idler" => (I, g.idler), "pick_cup_gear" => (P, g.pick))
    pairs = (("drive_pinion", "feed_cup_gear", (G.feed + 2.1, G.feed + 11.9)), ("feed_cup_gear", "idler", (G.feed + 1.6, G.idler[2] - 1.6)),
             ("idler", "pick_cup_gear", (G.pick + 2.1, G.pick + 11.9)))
    for (a, h, us) in pairs
        ca, ga = design[a]
        ch, gh = design[h]
        A, H = axes[a], axes[h]
        for u in us
            x = left_x(d, b, u)
            pa = moved(section(printed[a], x), Vec2d(A - ca) - profile_drift(printed, a, x, ca))
            ph = moved(section(printed[h], x), Vec2d(H - ch) - profile_drift(printed, h, x, ch))
            ratio = ga.teeth / gh.teeth
            pitch = 2π / ga.teeth
            jam = 0.0
            play = Inf
            for k in 0:(steps - 1)
                θ = k * pitch / steps
                ta = turned(pa, A, θ)
                th = turned(ph, H, -θ * ratio)
                jam = max(jam, overlap(ta, th))
                touch(δ) = overlap(ta, turned(th, H, δ)) > 1.0e-4
                side(s) = (lo = 0.0; hi = s * deg2rad(6.0); touch(hi) || return Inf;
                    for _ in 1:30
                        mid = (lo + hi) / 2
                        touch(mid) ? (hi = mid) : (lo = mid)
                    end; abs(lo))
                play = min(play, (side(1) + side(-1)) * pitch_radius(gh))
            end
            push!(rows, (pair = "$a / $h", x = round(x; digits = 1), jam = round(jam; digits = 4), backlash = round(play; digits = 3)))
        end
    end
    return rows
end

"""
    pawl_check(printed, d, b)

Each freewheel as printed: how far the pawl's tip reaches below the ratchet's tooth tips (it
must, to catch a tooth, and it bends that far when the roller runs ahead), the printed pawl's
thickness, and from both, by beam theory, its bending strain and the drag at the roller.
"""
function pawl_check(printed::Dict{String, PrintedPart}, d::FeederDesign = FeederDesign(), b::Build = Build();
        E = 1460.0, depth = 7.0, inner = 17.0)
    l = Layout(d, b)
    map((("feed", l.feed, GEAR_PLANES.feed + 3.6), ("pick", l.pick, GEAR_PLANES.pick + 3.6))) do (name, c, u)
        x = left_x(d, b, u)
        rat = moved(section(printed["$(name)_ratchet"], x), -profile_drift(printed, "$(name)_ratchet", x, c))
        cup = moved(section(printed["$(name)_cup_gear"], x), -profile_drift(printed, "$(name)_cup_gear", x, c))
        root, tip = radii(rat, c)
        pawl = GEOS.intersection(cup, disk(c, inner - 0.6))
        reach, _ = radii(pawl, c)
        φ = deg2rad(15.0)
        len = pawl_length(Vec2d(8.85, 0.0), Vec2d(sin(φ), -cos(φ)), inner + 0.5)
        t = GEOS.area(pawl) / pawl_length(Vec2d(8.85, 0.0), Vec2d(sin(φ), -cos(φ)), inner - 0.6)
        bend = tip - reach
        strain = 3 * t * bend / (2 * len^2) * 100
        F = 3 * E * (depth * t^3 / 12) / len^3 * bend / 2
        ramp = atan((tip - root) / (0.9 * 2π * tip / 12))
        drag = F * (0.3 + tan(ramp)) * tip / d.feed_radius
        (freewheel = name, tooth = round(tip - root; digits = 2), catches = round(bend; digits = 2), pawl = round(t; digits = 2),
         strain = round(strain; digits = 2), drag = round(drag; digits = 3))
    end
end

"""
    leaf_thickness(printed, name, x, a, c; margin = 4)

Thickness of a printed leaf spring between its ends `a` and `c` (profile points), from the
area of its section between them, `margin` away from each end.
"""
function leaf_thickness(printed::Dict{String, PrintedPart}, name, x, a::Point2d, c::Point2d; margin = 4.0, width = 3.0)
    u = normalize(Vec2d(c - a))
    n = Vec2d(-u[2], u[1])
    L = norm(Vec2d(c - a)) - 2margin
    p0 = a + margin * u
    corners = [p0 - width * n, p0 + L * u - width * n, p0 + L * u + width * n, p0 + width * n]
    strip = GEOS.Polygon([[[q[1], q[2]] for q in vcat(corners, corners[1:1])]])
    return GEOS.area(GEOS.intersection(section(printed[name], x), strip)) / L
end

"""
    spring_check(printed, d, b)

The printed leaf springs' thickness and the force that gives (∝ t³) against the design: the
pad spring (1.2 mm, `PAD_FORCE`) and the idler springs (2.6 mm).
"""
function spring_check(printed::Dict{String, PrintedPart}, d::FeederDesign = FeederDesign(), b::Build = Build())
    l = Layout(d, b)
    p = l.profile
    u0, u1 = l.pad_leaf
    a, c = at_nip(p, u0, l.pad_depth) + deflection(PAD_LEAF, PAD_FORCE) * left(p.entry), at_nip(p, u1, l.pad_depth)
    pad = leaf_thickness(printed, "pad_spring", 0.1, a, c)
    o = d.inner_width / 2 + b.plate
    leaf = IDLER_LEAF
    bottom = l.exit_low[2] - b.shaft / 2
    tip = Point2d(l.exit_low[1] + 4.0, bottom + deflection(leaf, 1.5) - leaf.thickness / 2)
    root = Point2d(l.exit_low[1] - leaf.length, bottom - leaf.thickness / 2)
    idlers = [leaf_thickness(printed, "idler_spring_$s", side * (o + 1.0 + leaf.width / 2), root, tip) for (s, side) in (("l", -1), ("r", 1))]
    [(spring = "pad_spring", designed = PAD_LEAF.thickness, printed = round(pad; digits = 3), force = round((pad / PAD_LEAF.thickness)^3; digits = 2)),
     (spring = "idler_spring_l", designed = leaf.thickness, printed = round(idlers[1]; digits = 3), force = round((idlers[1] / leaf.thickness)^3; digits = 2)),
     (spring = "idler_spring_r", designed = leaf.thickness, printed = round(idlers[2]; digits = 3), force = round((idlers[2] / leaf.thickness)^3; digits = 2))]
end

"""
    slot_check(printed, d, l)

Each cable slot in its printed plate, through the plate and in the pockets' depth: the slot
must stay a hole of its own (not run into a pocket, bore or peg hole) with at least `web` mm
of plastic to the next hole, and the motor's plug (JST XHP-5, `XHP5`) must pass through it
with `room` mm to spare all around.
"""
function slot_check(printed::Dict{String, PrintedPart}, d::FeederDesign, b::Build, l::Layout; web = 1.5, room = 0.5)
    W2, o = d.inner_width / 2, d.inner_width / 2 + b.plate
    map(cable_slots(d, l)) do (side, y, z)
        plate = printed[side < 0 ? "side_plate_left" : "side_plate_right"]
        worst_area, worst_web, passes = 0.0, Inf, true
        for x in side .* (W2 + 1.1, W2 + 4.1, o - 1.1)
            s = section(plate, x)
            c = GEOS.Point(y, z)
            for poly in polygons(s)
                rings = GEOS.interiorRings(poly)
                k = findfirst(r -> GEOS.contains(GEOS.Polygon(r, GEOS.LinearRing[]), c), rings)
                k === nothing && continue
                hole = GEOS.Polygon(rings[k], GEOS.LinearRing[])
                # Holes under 1 mm² are gaps between beads, not features.
                others = filter(q -> GEOS.area(q) > 1.0, [GEOS.Polygon(r, GEOS.LinearRing[]) for (i, r) in enumerate(rings) if i != k])
                worst_area = max(worst_area, GEOS.area(hole))
                isempty(others) || (worst_web = min(worst_web, minimum(q -> GEOS.distance(hole, q), others)))
                m = GEOS.GeoInterface.coordinates(GEOS.centroid(hole))
                plug = rect(Point2d(m[1] - XHP5[1] / 2 - room, m[2] - XHP5[2] / 2 - room), Point2d(m[1] + XHP5[1] / 2 + room, m[2] + XHP5[2] / 2 + room))
                passes &= GEOS.within(plug, hole)
            end
        end
        (side = side, y = round(y; digits = 1), z = round(z; digits = 1), area = round(worst_area; digits = 1),
         web = round(worst_web; digits = 2), plug_passes = passes,
         ok = 0 < worst_area < prod(CABLE_SLOT) * 1.1 && worst_web >= web && passes)
    end
end

"""
    printed_interference(printed; step = 1.0, tolerance = 0.05)

Every pair of printed parts that overlap, from cuts across the whole feeder every `step` mm
along x: the volume they share (mm³, cut area times step) and the deepest overlap (mm, the
largest overlap area per mm of its outline). Parts stay where they were printed for, each
cooled toward its own middle. Pairs that are meant to press together show up too.
"""
function printed_interference(printed::Dict{String, PrintedPart}; step = 1.0, tolerance = 0.05)
    names = collect(keys(printed))
    extent = Dict(n => x_extent(printed[n]) for n in names)
    lo, hi = minimum(first(e) for e in values(extent)), maximum(last(e) for e in values(extent))
    shared = Dict{Tuple{String, String}, Vector{Float64}}()
    for x in (lo + step / 2 + 0.037):step:hi
        here = [n for n in names if extent[n][1] < x < extent[n][2]]
        cuts = Dict(n => section(printed[n], x) for n in here)
        boxes = Dict(n => GEOS.envelope(cuts[n]) for n in here)
        for i in eachindex(here), j in (i + 1):length(here)
            a, b = here[i], here[j]
            GEOS.intersects(boxes[a], boxes[b]) || continue
            o = GEOS.intersection(cuts[a], cuts[b])
            area = GEOS.area(o)
            area > 1.0e-3 || continue
            depth = 2area / max(GEOS.geomLength(o), 1.0e-9)
            key = a < b ? (a, b) : (b, a)
            v = get!(shared, key, [0.0, 0.0])
            v[1] += area * step
            v[2] = max(v[2], depth)
        end
    end
    hits = [(a = k[1], b = k[2], volume = round(v[1]; digits = 2), depth = round(v[2]; digits = 3)) for (k, v) in shared if v[1] > tolerance]
    return sort!(hits; by = h -> -h.volume)
end

"An axis-aligned rectangle from `lo` to `hi` as a LibGEOS polygon."
rect(lo::Point2d, hi::Point2d) = GEOS.Polygon([[[lo[1], lo[2]], [hi[1], lo[2]], [hi[1], hi[2]], [lo[1], hi[2]], [lo[1], lo[2]]]])

"""
    lug_check(printed, d, b)

Each motor's lug over its two printed lug pins, in the lug's plane: the pins where their host's
printed holes put them, the motor laid over them where it fits best (its holes 35 ± 0.2 mm
apart, Rajguru's tolerance, the wider one, and 3.85 mm, the smallest the drawings allow).
`gap` is the smallest radial room between a pin and its hole (≥ 0: the motor goes on) and
`shift` how far that puts the motor's axis off the host's hole for its boss or shaft, against
the room that hole leaves (`play`).
"""
function lug_check(printed::Dict{String, PrintedPart}, d::FeederDesign = FeederDesign(), b::Build = Build())
    l = Layout(d, b)
    g = l.gearbox
    o = d.inner_width / 2 + b.plate
    mface = -(o + GEAR_PLANES.face)
    motors = (("drive", g.motor, g.turn, "drive_bracket", mface - 0.4, mface + 1.5, 0.4),
              ("exit", l.exit_up, l.exit_turn, "side_plate_right", o + 0.4, o - 3.0, b.bore))
    map(motors) do (name, c, turn, host, x, xh, play)
        prefix = name == "drive" ? "drive_lug_pin" : "exit_lug_pin"
        pins = map(enumerate(byj48_holes(c, turn))) do (k, h)
            p = moved(section(printed["$(prefix)_$k"], x), profile_drift(printed, host, xh, h) - profile_drift(printed, "$(prefix)_$k", x, h))
            m = GEOS.GeoInterface.coordinates(GEOS.centroid(p))
            q = Point2d(m[1], m[2])
            (center = q, radius = last(radii(p, q)))
        end
        mid = (pins[1].center + Vec2d(pins[2].center)) / 2
        u = normalize(Vec2d(pins[1].center - pins[2].center))
        gap = Inf
        for spacing in (BYJ48.holes - 0.2, BYJ48.holes + 0.2), (k, s) in ((1, 1), (2, -1))
            hole = mid + s * spacing / 2 * u
            gap = min(gap, BYJ48.hole_min / 2 - norm(Vec2d(pins[k].center - hole)) - pins[k].radius)
        end
        # The motor's body center, from the pins, against where its host holds the axis.
        held = c + profile_drift(printed, host, xh, c)
        shift = norm(Vec2d(mid - (held + BYJ48.offset * turn)))
        (motor = name, gap = round(gap; digits = 3), shift = round(shift; digits = 3), play = play, ok = gap >= 0 && shift <= play)
    end
end

"""
    board_check(printed, d, b)

Each bought board in its printed holder, from horizontal cuts through the printed carrier and
clamp frame (both print flat), for the smallest and the largest board its listing allows,
pushed into every corner of its pocket. The frame rests on the highest printed post and sits
where its pegs meet the posts' holes.

- `fit`: gap between the largest board and the posts, mm (≥ 0: it drops in);
- `support`: smallest shelf area under one of a board's corners, mm², holes taken out (≥ 1);
- `hold`: smallest finger area over one of its corners, mm² (≥ 1);
- `zones`: area of shelves and fingers inside the pocket but outside the boards' corner zones,
  where their parts are (0);
- `lift`: room between the thickest board (1.76 mm) and the fingers, mm (≥ 0);
- `pegs`: the smallest overlap of a frame peg with its post's hole, mm² (> 0: it grips), and
  `peg_end` the room below the pegs, mm (≥ 0).
"""
function board_check(printed::Dict{String, PrintedPart}, d::FeederDesign = FeederDesign(), b::Build = Build(); pcb_max = 1.76)
    l = Layout(d, b)
    carrier = printed["electronics_carrier"]
    H = HOLDER
    map(BOARDS) do bd
        f = board_frame(d, l, bd)
        frame = printed["$(bd.name)_clamp"]
        C = f.center
        v = drift(carrier, Vec3d(C[1], C[2], f.shelf))
        dc = Vec2d(v[1], v[2])
        v = drift(frame, Vec3d(C[1], C[2], f.top))
        dk = dc - Vec2d(v[1], v[2])                      # moves the frame onto the carrier's holes
        top_at(part, q, shift = Vec2d(0, 0)) = last(something(z_extent(part, (q - shift)...), (NaN, NaN)))
        bottom_at(part, q, shift = Vec2d(0, 0)) = first(something(z_extent(part, (q - shift)...), (NaN, NaN)))
        shelf_top = maximum(top_at(carrier, P - Vec2d(sx, sy) * H.shelf / 2 + dc) for (P, (sx, sy)) in f.corners)
        post_top = maximum(top_at(carrier, P + Vec2d(sx * (H.post - 0.8), -sy * 0.8) + dc) for (P, (sx, sy)) in f.corners)
        under = minimum(bottom_at(frame, P + Vec2d(sx * (H.post - 0.8), -sy * 0.8) + dc, dk) for (P, (sx, sy)) in f.corners)
        dz = post_top - under
        fx, fy = finger_reach(bd)
        finger = minimum(bottom_at(frame, P - Vec2d(sx * fx, sy * fy) / 2 + dc, dk) for (P, (sx, sy)) in f.corners) + dz
        pegs = [q + dc for q in holder_pegs(f)]
        peg_end = minimum(bottom_at(frame, q, dk) + dz - top_at(carrier, q) for q in pegs)
        # Boards as rectangles, holes and corner zones taken out where they count.
        Cp = C + dc
        board(s, at) = rect(Cp + at - Vec2d(s[1], s[2]) / 2, Cp + at + Vec2d(s[1], s[2]) / 2)
        hx, hy, hr = bd.hole
        function solid(s, at)
            g = board(s, at)
            for kx in (-1, 1), ky in (-1, 1)
                g = GEOS.difference(g, disk(Cp + at + Vec2d(kx * (s[1] / 2 - hx), ky * (s[2] / 2 - hy)), hr + 0.3))
            end
            return g
        end
        function busy(s, at, (zx, zy))
            lo, hi = Cp + at - Vec2d(s[1], s[2]) / 2, Cp + at + Vec2d(s[1], s[2]) / 2
            return GEOS.union(rect(lo + Vec2d(zx, 0), hi - Vec2d(zx, 0)), rect(lo + Vec2d(0, zy), hi - Vec2d(0, zy)))
        end
        quadrant(at, kx, ky) = rect(Cp + at + Vec2d(min(0, 100kx), min(0, 100ky)), Cp + at + Vec2d(max(0, 100kx), max(0, 100ky)))
        small = (bd.size[1] - bd.spread[1], bd.size[2] - bd.spread[2])
        large = (bd.size[1] + bd.spread[1], bd.size[2] + bd.spread[2])
        positions(s) = [Vec2d(kx * (f.hx - s[1] / 2), ky * (f.hy - s[2] / 2)) for kx in (-1, 1) for ky in (-1, 1)]
        fit = minimum([(o = overlap(board(large, Vec2d(0, 0)), plan(carrier, shelf_top + h)); o > 1.0e-4 ? -o : gap(board(large, Vec2d(0, 0)), plan(carrier, shelf_top + h))) for h in (0.1, 0.8, 1.5)])
        shelves = plan(carrier, shelf_top - 0.1)
        deep = plan(carrier, shelf_top - 2.4)
        fingers = moved(plan(frame, finger + 0.1 - dz), dk)
        # What reaches into the pocket: the walls and the frame's ring end at its edge (swollen
        # and shrunk 0.3 mm at most; `fit` checks that the board still drops in), the shelves and
        # fingers go on inside.
        pocket = rect(Cp - Vec2d(f.hx - 0.4, f.hy - 0.4), Cp + Vec2d(f.hx - 0.4, f.hy - 0.4))
        inner(g) = GEOS.intersection(g, pocket)
        support, hold, zones = Inf, Inf, 0.0
        for s in (small, large), at in positions(s)
            for kx in (-1, 1), ky in (-1, 1)
                corner = GEOS.intersection(solid(s, at), quadrant(at, kx, ky))
                s === small && (support = min(support, overlap(corner, shelves)); hold = min(hold, overlap(corner, fingers)))
            end
            zones = max(zones, overlap(busy(s, at, bd.clear.bottom), inner(shelves)), overlap(busy(s, at, bd.clear.bottom), inner(deep)),
                overlap(busy(s, at, bd.clear.top), inner(fingers)))
        end
        peg_grip = minimum(overlap(GEOS.intersection(moved(plan(frame, post_top - 2.0 - dz), dk), disk(q, LUG_PIN)), plan(carrier, post_top - 2.0)) for q in pegs)
        lift = finger - (shelf_top + pcb_max)
        (board = bd.name, fit = round(fit; digits = 3), support = round(support; digits = 2), hold = round(hold; digits = 2),
         zones = round(zones; digits = 3), lift = round(lift; digits = 2), pegs = round(peg_grip; digits = 3), peg_end = round(peg_end; digits = 2),
         ok = fit >= 0 && support >= 1 && hold >= 1 && zones < 1.0e-3 && lift >= 0 && peg_grip > 0 && peg_end >= 0)
    end
end
