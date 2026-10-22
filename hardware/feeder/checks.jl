# Checks of the construction before anything is printed: parts that overlap where they should
# not, and springs, motors and shafts against the loads the simulation found.

"The items that stand in the assembled feeder: without spare variants."
assembled(d::FeederDesign, b::Build) = filter(it -> it.group != :variants, items(d, b))

"The assembled feeder's items, traced for the GPU checks (`PrintSim.RayChecks`)."
PrintSim.RayChecks(d::FeederDesign, b::Build = Build(); rays = Rays()) = RayChecks(assembled(d, b); rays)

"The feeder built in the order of its assembly guide (`PrintSim.sequence_check`)."
PrintSim.sequence_check(c::RayChecks, d::FeederDesign, b::Build = Build(); kw...) = sequence_check(c, assembly_steps(d, b); kw...)

"Items that swing with the pick arm about the feed shaft."
const SWINGING = r"^(arm_[lr]|pick_shaft|pick_hub|pick_orings|pick_clip_.*|pick_ratchet|pick_cup_gear|idler|idler_clip)$"

"Items that drop with the lower exit roller in its slots."
const IDLE_PARTS = r"^(exit_idle_shaft|exit_idler_\d|idler_\d_orings|exit_idle_clip_.*)$"

"""
    swing_pose(name, l, Δθ)

Where swinging item `name` goes when the arm turns by `Δθ` about the feed shaft. The idler rolls
on the standing feed gear as it goes, so it also turns about its own axis by Δθ·30/18, and the
pick gear by −Δθ (the other teeth keep meshing).
"""
function swing_pose(name, l::Layout, Δθ)
    F = l.feed
    arm = turn_x(Δθ, F)
    g = l.gearbox
    P = Point2d(F + rotate(Vec2d(l.pick - F), Δθ))
    name == "idler" && return turn_x(Δθ * g.feed.teeth / g.idler.teeth, idler_center(g, F, P)) ∘ arm
    name == "pick_cup_gear" && return turn_x(-Δθ, P) ∘ arm
    return arm
end

"Turns the solids `tags` of swinging item `name` as `swing_pose` says."
function swing!(tags, name, l::Layout, Δθ)
    p = swing_pose(name, l, Δθ)
    R, t = p.R, p.t
    occ().affineTransform(tags, Float64[R[1, 1], R[1, 2], R[1, 3], t[1], R[2, 1], R[2, 2], R[2, 3], t[2], R[3, 1], R[3, 2], R[3, 3], t[3]])
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
    motion_check(c::RayChecks, design, build; heights = (0, full stack, 15 mm above it))

Moves what moves and looks for collisions with everything else: the pick arm with all it
carries resting on an empty tray, on a full stack and lifted 15 mm above it for loading; the
lower exit roller at the bottom of its slot. Returns, per pose, the parts hit and the shared
volume.
"""
function motion_check(c::RayChecks, d::FeederDesign = FeederDesign(), b::Build = Build(); heights = (0.0, d.stack_height, d.stack_height + 15.0),
        tolerance = 0.5)
    l = Layout(d, b)
    arm = filter(n -> occursin(SWINGING, n), c.names)
    # The pick roller's O-rings rest on the tray when it is empty, the feed shaft runs in the arms' hubs:
    # those contacts are intended.
    results = ["pick arm at $(h) mm" => collisions(c, Dict(n => swing_pose(n, l, arm_turn(d, l, h)) for n in arm);
        ignore = h <= 0 ? ["tray", "feed_shaft"] : ["feed_shaft"], tolerance) for h in heights]
    idle = Dict(n => Pose(Vec3f(0, 0, -l.lift)) for n in c.names if occursin(IDLE_PARTS, n))
    springs = filter(n -> startswith(n, "idler_spring"), c.names)
    return push!(results, "lower exit roller $(l.lift) mm down" => collisions(c, idle; ignore = springs, tolerance))
end

"""
    insertion_check(c::RayChecks, design, build; reach = 400.0)

Every shaft goes in along x through the plates once the frame stands. The volume each shaft's
section sweeps from far outside to the far plate against the frame: only the parts it is meant
to pass may show up.
"""
function insertion_check(c::RayChecks, d::FeederDesign = FeederDesign(), b::Build = Build(); reach = 400.0, tolerance = 0.5)
    l = Layout(d, b)
    o = d.inner_width / 2 + b.plate
    frame = [it.name for it in assembled(d, b) if it.group == :frame || it.name in ("pad_spring", "pad_pin")]
    I = Pose()
    map((("pick_shaft", l.pick, -1), ("feed_shaft", l.feed, -1), ("exit_drive_shaft", l.exit_up, 1), ("exit_idle_shaft", l.exit_low, -1))) do (name, at, from)
        x0, x1 = from < 0 ? (-reach, o) : (-o, reach)
        swept = Traced(c.rays.backend, closed_surface(() -> shaft!(b, at, x0, x1)))
        pairs = [n for n in frame if overlaps(moved_box(swept, I), box(c, n))]
        v = shared(c.rays, [(swept, I, c.parts[n], I) for n in pairs])
        "$name from $(from < 0 ? "left" : "right")" => [n => x for (n, x) in zip(pairs, v) if x > tolerance]
    end
end

"""
What moves along x as one, for `axial_check`: each shaft with the parts that turn with it and
the clips in its grooves, the parts that turn on a shaft or post, and the pinion on the motor's
shaft. Everything else stands: the frame and what is fixed to it.
"""
const AXIAL_BODIES = [
    "feed shaft" => r"^(feed_shaft|feed_hub|feed_orings|feed_ratchet|feed_clip_.*)$",
    "pick shaft" => r"^(pick_shaft|pick_hub|pick_orings|pick_ratchet|pick_clip_.*)$",
    "driven exit shaft" => r"^(exit_drive_shaft|exit_hub_\d|exit_\d_orings|exit_drive_clip_.*)$",
    "exit idler shaft" => r"^(exit_idle_shaft|exit_idler_\d|idler_\d_orings|exit_idle_clip_.*)$",
    "feed cup gear" => r"^feed_cup_gear$", "pick cup gear" => r"^pick_cup_gear$",
    "left arm" => r"^(arm_l|idler_clip)$", "right arm" => r"^arm_r$", "idler" => r"^idler$",
    "pinion" => r"^drive_pinion$",
]

"The parts that slide on their shafts between their neighbours: hubs between clips, ratchets in their cups."
const AXIAL_PARTS = [
    "feed hub" => r"^feed_(hub|orings)$", "pick hub" => r"^pick_(hub|orings)$",
    "exit hub 1" => r"^exit_(hub_1|1_orings)$", "exit hub 2" => r"^exit_(hub_2|2_orings)$",
    "exit idler 1" => r"^(exit_idler_1|idler_1_orings)$", "exit idler 2" => r"^(exit_idler_2|idler_2_orings)$",
    "feed ratchet" => r"^feed_ratchet$", "pick ratchet" => r"^pick_ratchet$",
]

"How far the feeder's shafts and what turns on them slide along x (`PrintSim.axial_check`)."
PrintSim.axial_check(c::RayChecks, ::FeederDesign; kw...) = axial_check(c, AXIAL_BODIES, AXIAL_PARTS; kw...)

"""
    electronics_check(c::RayChecks, design, build; tolerance = 0.05)

The bought boards and the room they need (`board_envelopes`: their parts, the motor plugs, the
jumper wires and their bends, the USB-C plug and cable) against every printed part, for each
board at its smallest and its largest, pushed into every corner of its pocket. Returns the
volume each pair shares, mm³; empty when everything is clear.
"""
function electronics_check(c::RayChecks, d::FeederDesign = FeederDesign(), b::Build = Build(); tolerance = 0.05)
    l = Layout(d, b)
    printed_names = [it.name for it in assembled(d, b) if printed(it)]
    I = Pose()
    hits = NamedTuple{(:board, :size, :at, :part, :what, :volume), Tuple{String, Tuple{Float64, Float64}, Vec2d, String, Symbol, Float64}}[]
    for bd in BOARDS
        f = board_frame(d, l, bd)
        for s in ((bd.size[1] - bd.spread[1], bd.size[2] - bd.spread[2]), (bd.size[1] + bd.spread[1], bd.size[2] + bd.spread[2])), kx in (-1, 1), ky in (-1, 1)
            at = Vec2d(kx * (f.hx - s[1] / 2), ky * (f.hy - s[2] / 2))
            for (what, build) in ((:room, () -> fuse_all!(board_envelopes(d, l, bd; size = s, at))), (:board, () -> board!(d, l, bd; size = s, at)))
                part = Traced(c.rays.backend, closed_surface(build))
                near = [n for n in printed_names if overlaps(moved_box(part, I), box(c, n))]
                for (n, v) in zip(near, shared(c.rays, [(part, I, c.parts[n], I) for n in near]))
                    v > tolerance && push!(hits, (board = bd.name, size = s, at = at, part = n, what = what, volume = v))
                end
            end
        end
    end
    return hits
end

"""
    cable_route_check(c::RayChecks, design, build; radius = 2.0)

Each motor's lead along `cable_routes` as a tube (the five AWG 26 wires bundled, 4 mm thick)
against every part of the feeder and against the circles the gears' teeth sweep (1 mm wider):
the volume shared, mm³. The lead's first 2 mm leave the motor's housing and are left out.
"""
function cable_route_check(c::RayChecks, d::FeederDesign = FeederDesign(), b::Build = Build(); radius = 2.0, tolerance = 0.05)
    l = Layout(d, b)
    g = l.gearbox
    G = GEAR_PLANES
    span(u0, u1) = (left_x(d, b, u1), u1 - u0)
    swing = swing_points(l.profile, d)
    I = Pose()
    # Teeth with 1 mm to spare, and what swings with the arm wherever it goes.
    sweeps = ["pinion teeth" => () -> cylinder_x(g.motor, tip_radius(g.pinion) + 1.0, span(G.pinion...)...),
        "feed gear teeth" => () -> cylinder_x(l.feed, tip_radius(g.feed) + 1.0, span(G.feed, G.feed + 13.5)...),
        "pick gear teeth" => () -> fuse_all!(reduce(vcat, [cylinder_x(P, tip_radius(g.pick) + 1.0, span(G.pick, G.pick + 13.5)...) for P in swing])),
        "idler teeth" => () -> fuse_all!(reduce(vcat, [cylinder_x(idler_center(g, l.feed, P), tip_radius(g.idler) + 1.0, span(G.idler...)...) for P in swing])),
        "arm" => () -> fuse_all!(reduce(vcat, [cylinder_x(q, 9.0, span(G.arm...)...) for P in swing for q in (P, idler_center(g, l.feed, P))]))]
    others = vcat([n => c.parts[n] for n in c.names if !startswith(n, "coupon")],
        [name => Traced(c.rays.backend, closed_surface(build)) for (name, build) in sweeps])
    hits = NamedTuple{(:motor, :part, :volume), Tuple{String, String, Float64}}[]
    for r in cable_routes(d, b, l)
        pts = r.points
        path = vcat([pts[1] + 2.0 * normalize(pts[2] - pts[1])], pts[2:end])
        tube = Traced(c.rays.backend, closed_surface(() -> fuse_all!(reduce(vcat,
            [vcat([(3, occ().addCylinder(path[k]..., (path[k + 1] - path[k])..., radius))],
                  k > 1 ? [(3, occ().addSphere(path[k]..., radius))] : Tuple{Int32, Int32}[]) for k in 1:(length(path) - 1)]))))
        near = [(n, t) for (n, t) in others if n != r.board && overlaps(moved_box(tube, I), moved_box(t, I))]
        for ((n, _), v) in zip(near, shared(c.rays, [(tube, I, t, I) for (_, t) in near]))
            v > tolerance && push!(hits, (motor = r.motor, part = n, volume = v))
        end
    end
    return hits
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
    # The clips' grooves beside the rollers, where the shafts bend most: the round core the groove
    # leaves, its stress raised three times by the groove's corners.
    Ig, cg, Kt = π * CLIP.groove^4 / 4, CLIP.groove, 3.0
    xg = b.roller_length / 2 + 0.5 + CLIP.thickness / 2
    row!("feed shaft bending stress in a clip's groove", Kt * F / 2 * (span / 2 - xg) * cg / Ig, 7.0, "MPa")
    row!("pick shaft bending stress in a clip's groove", Kt * Fp / 2 * (arms / 2 - xg) * cg / Ig, 7.0, "MPa")
    row!("exit shaft bending stress in a clip's groove", Kt * P * a * cg / Ig, 7.0, "MPa")
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
the x and y ranges their shadow covers.
"""
function camera_check(d::FeederDesign = FeederDesign(), b::Build = Build(); piles = (0.0, 15.0))
    camera = Vec3d(0.0, d.box_length / 2, d.camera_height)
    list = filter(it -> it.name != "phone", assembled(d, b))
    hidden = Dict{Float64, Vector{NamedTuple{(:item, :points, :xs, :ys), Tuple{String, Int, NTuple{2, Float64}, NTuple{2, Float64}}}}}(z => [] for z in piles)
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
                shadow = Vec3d[]
                for q in pts
                    (q[3] > z + 0.5 && q[3] < camera[3]) || continue
                    s = camera + (camera[3] - z) / (camera[3] - q[3]) * (q - camera)
                    abs(s[1]) <= d.sheet_width / 2 && 0.0 <= s[2] <= d.box_length && push!(shadow, s)
                end
                isempty(shadow) || push!(hidden[z], (item = it.name, points = length(shadow), xs = extrema(first, shadow), ys = extrema(s -> s[2], shadow)))
            end
        end
    end
    return hidden
end
