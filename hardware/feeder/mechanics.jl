# Construction of the feeder: how the paper-path profile becomes parts that print and fit
# together. Everything here is in millimeters; x runs across the sheet, (y, z) is the profile.

"""
    Build(; kwargs...)

Construction details that the paper path does not fix: plate and shaft sizes, fits and the
clearances the Bambu H2D needs. Printed holes come out up to 0.3 mm small on the H2D; the
print simulation (`joint_report` on the parts rebuilt from the G-code) shows that turning fits
need 0.4 mm and pockets 0.3 mm of clearance to stay free when faces swell by 0.1 mm. The
tolerance coupon (`coupon!`) tries each fit 0.1 mm tighter and looser before the real parts.
"""
Base.@kwdef struct Build
    plate::Float64 = 8.0            # side plate thickness
    shaft::Float64 = 10.0           # D-shaft diameter
    flat::Float64 = 1.0             # depth of the shaft's flat
    bore::Float64 = 0.4             # radial clearance of a shaft turning in a plate
    grip::Float64 = 0.0             # radial clearance of D-bores that hold a part on a shaft
    slide::Float64 = 0.3            # clearance of parts sitting in pockets and slots
    pocket::Float64 = 3.0           # depth of the pockets in the plates for guides, tray and wall
    tie::Float64 = 12.0             # square tie bar
    wedge::Float64 = 4.0            # wedge head thickness; the slot leaves 3.5 mm outside the plate
    tenon::Float64 = 6.0            # how far a tenon reaches past the plate: short of the pick gear
    roller_length::Float64 = 30.0   # pick and feed roller
    exit_roller_length::Float64 = 16.0
    exit_rollers::NTuple{2, Float64} = (-55.0, 55.0)    # x of the exit roller pairs
    socket::Float64 = 0.0           # radial play of the D-sockets on the 28BYJ-48's shaft: printed holes come out small
end

"""
28BYJ-48 geared stepper (5 V), from the dimension drawings in the ANGEEK listing (the motors
the README links) and the Rajguru datasheet; the shaft axis is the origin. Where the two
differ, the worse value for a fit: the 1.8 mm boss (Rajguru: 1.5) and the 4.0 mm lug holes
(Rajguru: 4.2 ± 0.15). The shaft protrudes 10 ± 0.5 mm from the mounting face and is flattened
only over its outer 6 ± 0.2 mm; behind that it is round. The cable housing, 14.6 mm wide, covers
the 16 mm of the body next to the mounting face and reaches 17.1 mm from the body's axis; the
lead leaves it `cable_exit` = 3.5 mm behind the face (both drawings) and is 230 ± 10 mm long to
its plug (Rajguru; ANGEEK: 230 ± 5). `lug_thickness` is in neither drawing.
"""
const BYJ48 = (body = 28.0, depth = 19.0, offset = 8.0, boss = 9.0, boss_height = 1.8,
    shaft = 5.0, flats = 3.0, shaft_length = 10.0, flat_length = 6.0, length_tolerance = 0.5, flat_tolerance = 0.2,
    holes = 35.0, holes_tolerance = 0.2, hole = 4.0, hole_min = 3.85, lug_width = 7.0, lug_thickness = 0.85,
    cable_box = (14.6, 17.1, 16.0), cable_exit = 3.5, lead = 220.0)

# --- profile-plane helpers ----------------------------------------------------------------------

"""
Outline of a D-shaft cross section of diameter `d` with a flat `flat` deep, centered on `c`,
the flat facing `toward` (a unit vector in the profile plane).
"""
function d_outline(c::Point2d, d, flat, toward::Vec2d; n = 72)
    r = d / 2
    h = r - flat                       # distance of the flat from the center
    φf = atan(toward[2], toward[1])
    half = acos(h / r)                 # half angle of the arc removed by the flat
    arc = range(φf + half, φf + 2π - half; length = n)
    return [c + r * Vec2d(cos(t), sin(t)) for t in arc]
end

"A D-shaft section extruded across x."
d_prism(c, d, flat, toward, x0, width) = prism(d_outline(c, d, flat, toward), x0, width)

# --- shafts and what sits on them ----------------------------------------------------------------

"""
    shaft!(b, c, x0, x1; toward)

A D-shaft from `x0` to `x1` around profile point `c`, the flat facing `toward`. It prints
lying on its flat, so the flat also orients the parts clamped on it.
"""
shaft!(b::Build, c::Point2d, x0, x1; toward = Vec2d(0, -1)) = d_prism(c, b.shaft, b.flat, toward, x0, x1 - x0)

"""
A sleeve of outer `radius` and `length` on a D-shaft (a roller, a collar, a ratchet wheel): its
bore is the shaft's D with clearance `b.grip`.
"""
function sleeve!(b::Build, c::Point2d, radius, x0, length; toward = Vec2d(0, -1))
    body = cylinder_x(c, radius, x0, length)
    bore = d_prism(c, b.shaft + 2b.grip, b.flat - b.grip, toward, x0 - 1, length + 2)
    return cut!(body, bore)
end

"""
A split collar that snaps over the shaft from the side and keeps a roller from sliding: a
sleeve with a slot as wide as the shaft's flat chord minus a little, so it clicks into place.
"""
function collar!(b::Build, c::Point2d, x0; length = 5.0, radius = 8.0, toward = Vec2d(0, -1))
    s = sleeve!(b, c, radius, x0, length; toward)
    r = b.shaft / 2
    slot = 2 * sqrt(r^2 - (r - b.flat)^2) - 0.6
    away = -toward
    side = Vec2d(-away[2], away[1])
    gap = [c + slot / 2 * side, c + slot / 2 * side + (radius + 1) * away, c - slot / 2 * side + (radius + 1) * away, c - slot / 2 * side]
    return cut!(s, prism(gap, x0 - 1, length + 2))
end

# --- gears --------------------------------------------------------------------------------------

"""
    Gear(teeth; m = 1.5, pressure = 20.0, backlash = 0.25)

A printed involute spur gear: `teeth` teeth of module `m` (mm) and pressure angle `pressure`
(degrees). Each tooth is `backlash` mm thinner at the pitch circle than a perfect one, so
printed teeth, which come out a little fat, still mesh freely. At least 17 teeth, so no
tooth needs undercut.
"""
struct Gear
    teeth::Int
    m::Float64
    pressure::Float64
    backlash::Float64
end
Gear(teeth; m = 1.5, pressure = 20.0, backlash = 0.25) = Gear(teeth, m, pressure, backlash)

pitch_radius(g::Gear) = g.m * g.teeth / 2
tip_radius(g::Gear) = pitch_radius(g) + g.m
root_radius(g::Gear) = pitch_radius(g) - 1.25g.m

"Center distance of two meshing gears, with `play` mm extra for printed parts."
center_distance(a::Gear, b::Gear; play = 0.15) = pitch_radius(a) + pitch_radius(b) + play

involute_angle(a) = tan(a) - a

"""
    gear_outline(c, g; phase = 0.0, n = 7)

Outline of gear `g` around profile point `c`, counterclockwise, one tooth centered at angle
`phase`: involute flanks from the base (or root) circle to the tip, straight root between the
teeth.
"""
function gear_outline(c::Point2d, g::Gear; phase = 0.0, n = 7)
    α = deg2rad(g.pressure)
    rp, ra, rf = pitch_radius(g), tip_radius(g), root_radius(g)
    rb = rp * cos(α)
    ψ = (π * g.m / 2 - g.backlash) / (2rp)                       # half the tooth at the pitch circle
    half(r) = ψ + involute_angle(α) - involute_angle(acos(min(rb / r, 1.0)))
    r0 = max(rb, rf)
    radii = range(r0, ra; length = n)
    pts = Point2d[]
    polar(r, φ) = c + r * Vec2d(cos(φ), sin(φ))
    for k in 0:(g.teeth - 1)
        φ = phase + 2π * k / g.teeth
        rf < r0 && push!(pts, polar(rf, φ - half(r0)))
        append!(pts, [polar(r, φ - half(r)) for r in radii])
        append!(pts, [polar(r, φ + half(r)) for r in reverse(radii)])
        rf < r0 && push!(pts, polar(rf, φ + half(r0)))
    end
    return pts
end

"""
    mesh_phase(a, ca, phase_a, b, cb)

The phase of gear `b` at `cb` that meshes with gear `a` at `ca` turned to `phase_a`: a tooth of
`a` on the line of centers sits in a gap of `b`, and turning `a` turns `b` by the tooth ratio.
"""
function mesh_phase(a::Gear, ca::Point2d, phase_a, b::Gear, cb::Point2d)
    β = atan(cb[2] - ca[2], cb[1] - ca[1])
    δ = phase_a - β
    return β + π - π / b.teeth - δ * a.teeth / b.teeth
end

"Gear `g` around `c` from `x0` across `width`, with a round bore of `bore` radius (0: none)."
function gear!(c::Point2d, g::Gear, x0, width; phase = 0.0, bore = 0.0)
    body = prism(gear_outline(c, g; phase), x0, width)
    return bore > 0 ? cut!(body, cylinder_x(c, bore, x0 - 1, width + 2)) : body
end

# --- one-way clutch -------------------------------------------------------------------------------

"""
Sawtooth outline of a ratchet wheel around `c`: `teeth` teeth between `root` and `tip` radius.
The steep faces lead in the driving sense `spin` (+1 counterclockwise in the profile plane).
"""
function ratchet_outline(c::Point2d, root, tip, teeth, spin; n = 6)
    pts = Point2d[]
    pitch = 2π / teeth
    for k in 0:(teeth - 1)
        φ0 = k * pitch
        # Ramp from the root up to the tip, then straight down: the steep face looks forward.
        for j in 0:n
            u = j / n
            φ = φ0 + u * pitch * 0.9
            push!(pts, Point2d(cos(φ), sin(φ)) * (root + (tip - root) * u))
        end
        φs = φ0 + pitch * 0.9
        push!(pts, Point2d(cos(φs), sin(φs)) * root)
    end
    # Counterclockwise as built; mirrored across the y axis for the clockwise sense.
    spin < 0 && (pts = reverse!([Point2d(-q[1], q[2]) for q in pts]))
    return [c + Vec2d(q) for q in pts]
end

"""
    ratchet!(b, c, x0, width; spin, teeth = 12, root = 8.0, tip = 9.0)

The driven half of the freewheel: a ratchet wheel clamped on the roller's shaft end.
"""
function ratchet!(b::Build, c::Point2d, x0, width; spin, teeth = 12, root = 8.0, tip = 9.0, toward = Vec2d(0, -1))
    wheel = prism(ratchet_outline(c, root, tip, teeth, spin), x0, width)
    bore = d_prism(c, b.shaft + 2b.grip, b.flat - b.grip, toward, x0 - 1, width + 2)
    return cut!(wheel, bore)
end

"""
Thickness (mm) of the freewheels' pawl: with the 20:30 gears a blocked roller loads it with 1.5
times the motor's torque, which a 0.8 mm beam would only just carry without buckling.
"""
const PAWL = 0.9

"""
    cup_gear!(b, c, rim, opening; gear, phase, spin, ...)

The driving half of a freewheel: a gear that turns freely on the roller's shaft, its hub a cup
with a flexible pawl inside. The pawl pushes the ratchet's steep faces in the driving sense
`spin` and clicks over the teeth when the roller runs ahead. The cup's rim is at x = `rim` and
it opens toward `opening` (+1: +x); its base and the hub behind it turn on the shaft over
6.5 mm. The teeth run over the whole width, so the part prints standing on its hub without
any overhang. One pawl keeps the drag low while the roller runs ahead; it is a 0.9 mm (`PAWL`) PETG
beam at 15° to the tangent whose tip sits at radius `reach`, so it catches the ratchet's 1 mm
teeth about 0.7 mm deep (`pawl_check`); it flexes in the print plane.
"""
function cup_gear!(b::Build, c::Point2d, rim, opening; gear::Gear, phase = 0.0, spin, depth = 7.0, base = 2.5, boss = 4.0,
        inner = 17.0, reach = 8.55, angle = 15.0, thickness = PAWL, pawls = 1)
    root_radius(gear) >= inner + 2.0 || error("the cup needs a gear whose root clears its 2 mm wall")
    xi0, wi = opening > 0 ? (rim - depth, depth) : (rim, depth)
    xb0, wb = opening > 0 ? (rim - depth - base, base) : (rim + depth, base)
    xs0, ws = opening > 0 ? (rim - depth - base - boss, boss) : (rim + depth + base, boss)
    cup = gear!(c, gear, min(xi0, xb0, xs0), depth + base + boss; phase)
    cup = cut!(cup, cylinder_x(c, inner, opening > 0 ? xi0 : xi0 - 1, wi + 1))
    for k in 0:(pawls - 1)
        φ = k * 2π / pawls
        t = c + reach * Vec2d(cos(φ), sin(φ))
        tangent = spin * Vec2d(-sin(φ), cos(φ))
        radial = Vec2d(cos(φ), sin(φ))
        dir = normalize(-tangent * cos(deg2rad(angle)) + radial * sin(deg2rad(angle)))
        root = t + pawl_length(Vec2d(t - c), dir, inner + 0.5) * dir      # where the beam meets the wall
        n = Vec2d(-dir[2], dir[1]) * thickness / 2
        cup = fuse!(cup, prism([t + n, root + n, root - n, t - n], xi0, wi))
    end
    return cut!(cup, cylinder_x(c, b.shaft / 2 + b.bore, min(xs0, xb0) - 1, ws + wb + 2))
end

"""
    motor_socket(c, face, toward; play, round_play = 0.2)

The socket for a 28BYJ-48's shaft around `c` whose motor's mounting face is at x = `face`,
the shaft pointing along `toward` (±1), as a tool to cut. The shaft is round near the motor
and flattened only further out, so the socket is round (`round_play` wider) as far as the
round part can reach with the drawing's tolerances, then a D (`play` wider) as far as the
longest shaft can reach, plus 0.5 mm.
"""
function motor_socket(c::Point2d, face, toward; play, round_play = 0.2)
    m = BYJ48
    # Distances from the mounting face: the round part ends at the latest at s_d, the tip at the latest at s_tip.
    s_d = m.shaft_length + m.length_tolerance - (m.flat_length - m.flat_tolerance) + 0.2
    s_tip = m.shaft_length + m.length_tolerance + 0.5
    span(a, b) = toward > 0 ? (face + a, b - a) : (face - b, b - a)
    x0, w = span(0.0, s_d)
    round_part = cylinder_x(c, m.shaft / 2 + round_play, x0, w)
    x0, w = span(s_d - 0.01, s_tip)
    r = m.shaft / 2 + play
    hole = cylinder_x(c, r, x0, w)
    keep = prism([c + Vec2d(-r - 1, -m.flats / 2 - play), c + Vec2d(r + 1, -m.flats / 2 - play),
        c + Vec2d(r + 1, m.flats / 2 + play), c + Vec2d(-r - 1, m.flats / 2 + play)], x0, w)
    return vcat(round_part, first(occ().intersect(hole, keep)))
end

"Length along `dir` from a point at offset `r` from the center to the circle of radius `R`."
function pawl_length(r::Vec2d, dir::Vec2d, R)
    b = dot(r, dir)
    return -b + sqrt(b^2 - dot(r, r) + R^2)
end

# --- the motor, as a part for clearance checks -----------------------------------------------------

"""
    byj48!(c, face, outward; turn)

A 28BYJ-48 with its shaft on profile point `c`, mounting face at x = `face`, body toward
`outward` (+1 or -1 along x). `turn` is the direction (profile plane) from the shaft to the
body center.
"""
function byj48!(c::Point2d, face, outward; turn::Vec2d)
    m = BYJ48
    center = c + m.offset * turn
    xb = outward > 0 ? face : face - m.depth
    body = cylinder_x(center, m.body / 2, xb, m.depth)
    side = Vec2d(-turn[2], turn[1])
    xl = outward > 0 ? face : face - m.lug_thickness
    lug = prism([center + (m.holes / 2 + 3.5) * side + 3.5 * turn, center - (m.holes / 2 + 3.5) * side + 3.5 * turn,
        center - (m.holes / 2 + 3.5) * side - 3.5 * turn, center + (m.holes / 2 + 3.5) * side - 3.5 * turn], xl, m.lug_thickness)
    body = fuse!(body, lug)
    xs = outward > 0 ? face - m.boss_height : face
    body = fuse!(body, cylinder_x(c, m.boss / 2, xs, m.boss_height))
    # The shaft: round from the face, flattened over its outer `flat_length`.
    round_length = m.shaft_length - m.flat_length
    xr = outward > 0 ? face - round_length : face
    body = fuse!(body, cylinder_x(c, m.shaft / 2, xr, round_length))
    xs = outward > 0 ? face - m.shaft_length : face + round_length
    shaft = cylinder_x(c, m.shaft / 2, xs, m.flat_length)
    keep = prism([c + Vec2d(-3, -m.flats / 2), c + Vec2d(3, -m.flats / 2), c + Vec2d(3, m.flats / 2), c + Vec2d(-3, m.flats / 2)],
        xs - 1, m.flat_length + 2)
    body = fuse!(body, first(occ().intersect(shaft, keep)))
    for h in byj48_holes(c, turn)
        body = cut!(body, cylinder_x(h, m.hole / 2, xl - 1, m.lug_thickness + 2))
    end
    # Cable housing: on the body's side away from the shaft, out to `reach` from the body's axis,
    # next to the mounting face.
    bx, reach, bz = m.cable_box
    inner = m.body / 2 - 4.0
    xc = outward > 0 ? face : face - bz
    cable = prism([center + bx / 2 * side + reach * turn, center - bx / 2 * side + reach * turn,
        center - bx / 2 * side + inner * turn, center + bx / 2 * side + inner * turn], xc, bz)
    return fuse!(body, cable)
end

"The two lug holes of a 28BYJ-48 mounted with its shaft on `c` and body toward `turn`."
function byj48_holes(c::Point2d, turn::Vec2d)
    center = c + BYJ48.offset * turn
    side = Vec2d(-turn[2], turn[1])
    return (center + BYJ48.holes / 2 * side, center - BYJ48.holes / 2 * side)
end

# --- springs ----------------------------------------------------------------------------------

"""
    Leaf(; length, thickness, width, material)

A rectangular cantilever leaf spring. `force(leaf, δ)` and `stress(leaf, δ)` give tip force (N)
and root bending stress (MPa) at tip deflection δ (mm), from beam theory.
"""
Base.@kwdef struct Leaf
    length::Float64
    thickness::Float64
    width::Float64
    modulus::Float64 = 1460.0       # MPa, Bambu PETG Basic, X-Y
end

stiffness(l::Leaf) = 3 * l.modulus * (l.width * l.thickness^3 / 12) / l.length^3   # N/mm
force(l::Leaf, δ) = stiffness(l) * δ
stress(l::Leaf, δ) = 6 * force(l, δ) * l.length / (l.width * l.thickness^2)
strain(l::Leaf, δ) = stress(l, δ) / l.modulus

"Deflection that gives `F` newtons."
deflection(l::Leaf, F) = F / stiffness(l)

# --- the pick arm and the gearbox: one motor turns feed and pick roller ---------------------------

"""
Where the drive sits outside the left plate, as distances (mm) out from its outer face: the pick
arm, the pick roller's cup gear, the feed roller's cup gear and the collar that keeps it on the
feed shaft, the arm's idler and its collar, the pinion and the drive motor's mounting face. Both
cup gears open toward the plate, their ratchets inside. The pinion meshes the feed gear; the
idler is wide enough to mesh both cup gears. The pick gear turns between the arm and the feed
gear, the pick shaft ends in it: nothing on the pick shaft reaches the feed gear's plane.
"""
const GEAR_PLANES = (arm = (0.5, 6.0), pick = 6.5, feed = 20.5, collar = 34.5, idler = (6.5, 28.0), idler_collar = 28.5,
    pinion = (20.5, 38.5), face = 42.0)

"""
    Gearbox(profile, design; reach = 14.5)

One motor turns pick and feed roller. Its pinion (20 teeth) drives the feed roller's cup gear
(30), which turns freely on the feed shaft and drives it through a freewheel; the pick arm
swings about the feed shaft and carries an idler (18) that the feed gear turns and that turns
the pick roller's cup gear (30), freewheel again. Both rollers turn 1.5 times slower than the
motor, at the same speed. The idler sits midway between the shafts, on the side of the arm away
from the paper (`idler_at`: along the arm and across it).

The pinion sits on the feed gear's circle where the idler never comes near it, the motor body
pointing from it along `turn`; the bracket's legs, `reach` beyond the lug holes, stand on the
plate clear of everything the arm swings through, and the motor's lead leaves its housing over
the plate. Of the places that work, the lowest motor.
"""
struct Gearbox
    pinion::Gear
    feed::Gear
    idler::Gear
    pick::Gear
    motor::Point2d                  # pinion axis
    turn::Vec2d                     # from the pinion axis to the motor body center
    reach::Float64                  # bracket legs beyond the lug holes
    idler_at::NTuple{2, Float64}
end

"Center of the arm's idler with the pick shaft at `P`."
function idler_center(g::Gearbox, F::Point2d, P::Point2d)
    u = normalize(Vec2d(P - F))
    return F + g.idler_at[1] * u + g.idler_at[2] * Vec2d(u[2], -u[1])
end

"The arm's positions: pick shaft centers from resting on an empty tray to lifted for loading."
swing_points(p::Profile, d::FeederDesign; lift = 15.0, n = 12) = [pick_center(p, d, h) for h in range(-1.0, d.stack_height + lift; length = n)]

function Gearbox(p::Profile, d::FeederDesign; reach = 14.5, margin = 1.5, leg = 8.0)
    pinion, feed, idler, pick = Gear(20), Gear(30), Gear(18), Gear(30)
    F = p.feed
    a = d.pick_arm / 2
    idler_at = (a, sqrt(center_distance(feed, idler)^2 - a^2))
    probe = Gearbox(pinion, feed, idler, pick, F, Vec2d(0, -1), reach, idler_at)
    swing = swing_points(p, d)
    idlers = [idler_center(probe, F, P) for P in swing]
    # Disks the bracket legs must clear: the feed gear, and the pick gear, idler and arm wherever they swing; the
    # lower exit shaft's end, also dropped, and the idler spring on the plate below it.
    E = p.exit_low
    spring = [Point2d(E[1] + t, E[2] - z) for t in range(-IDLER_LEAF.length - 18.0, 6.0; length = 8) for z in (5.0, 13.0)]
    keep_out = vcat([(F, tip_radius(feed))], [(P, tip_radius(pick)) for P in swing], [(I, tip_radius(idler)) for I in idlers],
        [(F + t * (P - F), 9.0) for P in swing for t in 0:0.25:1], [(F + t * (I - F), 9.0) for I in idlers for t in 0:0.25:1],
        [(E - Vec2d(0, t), 8.0) for t in 0:1.0:3.0], [(q, 8.0) for q in spring])
    front = -d.box_wall - 5.0 - leg
    rim = d.box_height + 2.0 + leg
    function fits(M, t)
        minimum(norm(M - I) for I in idlers) >= tip_radius(pinion) + tip_radius(idler) + margin || return false
        side = Vec2d(-t[2], t[1])
        body = M + BYJ48.offset * t
        feet = (body + (BYJ48.holes / 2 + reach) * side, body - (BYJ48.holes / 2 + reach) * side)
        all(f -> f[1] <= front || f[2] >= rim, feet) || return false
        lead = M + (BYJ48.offset + BYJ48.cable_box[2]) * t           # where the motor's lead leaves its housing
        (lead[1] <= front || lead[2] >= rim) || return false
        return all(norm(f - c) - r >= leg / sqrt(2) + margin for f in feet for (c, r) in keep_out)
    end
    ring = center_distance(pinion, feed)
    options = [(M, t) for φ in range(0, 2π; length = 73)[1:(end - 1)] for M in (F + ring * Vec2d(cos(φ), sin(φ)),)
               for ψ in range(0, 2π; length = 73)[1:(end - 1)] for t in (Vec2d(cos(ψ), sin(ψ)),) if fits(M, t)]
    isempty(options) && error("no place for the drive motor keeps its pinion off the idler and its bracket legs clear")
    M, t = argmin(o -> (o[1] + BYJ48.offset * o[2])[2], options)
    return Gearbox(pinion, feed, idler, pick, Point2d(M), t, reach, idler_at)
end

"Turning phase of each gear (pinion, feed, idler, pick) with the pick shaft at `P`, so the teeth mesh."
function gear_phases(g::Gearbox, F::Point2d, P::Point2d)
    I = idler_center(g, F, P)
    feed = mesh_phase(g.pinion, g.motor, 0.0, g.feed, F)
    idler = mesh_phase(g.feed, F, feed, g.idler, I)
    return (0.0, feed, idler, mesh_phase(g.idler, I, idler, g.pick, P))
end

"Pick roller speed over feed roller speed."
pick_ratio(g::Gearbox) = g.feed.teeth / g.pick.teeth

"x of a plane `u` mm out from the left plate's outer face."
left_x(d::FeederDesign, b::Build, u) = -(d.inner_width / 2 + b.plate) - u

"""
    pinion!(d, b, g)

The motor's pinion: as wide as the feed gear and on to 0.5 mm short of the bracket's face, with
a D-socket for the 28BYJ-48's shaft in its outer end.
"""
function pinion!(d::FeederDesign, b::Build, g::Gearbox)
    u0, u1 = GEAR_PLANES.pinion
    x1, x0 = left_x(d, b, u0), left_x(d, b, u1)
    body = gear!(g.motor, g.pinion, x0, x1 - x0)
    face = left_x(d, b, GEAR_PLANES.face)
    return cut!(body, motor_socket(g.motor, face, 1; play = b.socket))
end

"The gearbox bracket's two legs."
gearbox_feet(g::Gearbox) = bracket_feet(g.motor, g.turn; g.reach)

# --- layout: where the construction puts things ----------------------------------------------------

"""
    Layout(design, build)

Positions in the profile plane derived from the paper path: shafts (the pick shaft over a half
full stack), the pad spring, the bars that tie the side plates together and the side plate
outline. Motors sit on the outside of the plates: the gearbox for pick and feed roller on the
left (x < 0), the exit motor on the right, straight on the driven exit shaft.
"""
struct Layout
    profile::Profile
    pick::Point2d
    feed::Point2d
    exit_low::Point2d
    exit_up::Point2d
    lift::Float64                   # mm the lower exit roller can drop
    pad_leaf::NTuple{2, Float64}    # along the nip from it: the leaf's free end (at the pad head) and its root
    pad_depth::Float64              # the leaf's mid-plane below the nip with the pad resting on the roller
    pad_bar::Point2d                # tie bar that carries the pad spring
    ties::Vector{Point2d}           # tie bar centers, the pad bar first
    gearbox::Gearbox
    exit_turn::Vec2d                # from the exit shaft to the exit motor's body center
    outline::Vector{Point2d}
end

"Profile point `u` along the nip from it and `w` below it."
at_nip(p::Profile, u, w) = p.nip + u * p.entry - w * left(p.entry)

function Layout(d::FeederDesign, b::Build; lift = 3.0)
    p = Profile(d)
    gearbox = Gearbox(p, d)
    pick = pick_center(p, d, d.stack_height / 2)
    pad_leaf, pad_depth = (PAD_HEAD.u0, PAD_HEAD.u0 - PAD_LEAF.length), 20.0
    pad_bar = at_nip(p, pad_leaf[2] - 4.0, pad_depth + PAD_LEAF.thickness / 2 - 4.0)
    exit_turn = Vec2d(0, 1)
    m = 14.0                                            # margin around features
    rim = d.box_height + 2.0
    front = -d.box_wall - 5.0
    swing = swing_points(p, d)
    disks = vcat([(c, b.shaft / 2 + m) for c in (p.feed, p.exit_up)], [(c, b.shaft / 2 + 8.0) for c in swing],
        [(p.exit_low - Vec2d(0, lift), b.shaft / 2 + 8.0), (pad_bar, b.tie + 6.0), (p.tray.b, 10.0)])
    for c in (gearbox_feet(gearbox)..., byj48_holes(p.exit_up, exit_turn)...)
        push!(disks, (c, 9.0))
    end
    peg_y = p.exit_low[1] - IDLER_LEAF.length - 6
    push!(disks, (Point2d(peg_y, p.exit_low[2] - 10.0), 9.0))
    c = carrier_span(d)
    push!(disks, (Point2d(c.y0, c.z0), 8.0), (Point2d(c.y0, c.top + 60.0), 8.0))
    feature_points = reduce(vcat, [circle_points(c, r; n = 24) for (c, r) in disks])
    rear = minimum(first.(feature_points))
    rear_tie = Point2d(rear + 6.0, 10.0)
    front_tie = Point2d(front - 12.0, 10.0)
    base = Point2d[Point2d(rear, -d.box_wall), Point2d(front, -d.box_wall), Point2d(front, rim)]
    pts = vcat(feature_points, base, circle_points(rear_tie, 14.0; n = 16), circle_points(front_tie, 14.0; n = 16))
    outline = convex_hull(pts)
    return Layout(p, pick, p.feed, p.exit_low, p.exit_up, lift, pad_leaf, pad_depth, pad_bar, [pad_bar, rear_tie, front_tie],
        gearbox, exit_turn, outline)
end

"""
    arm!(d, b, l, side)

One side of the pick arm, outside a side plate: a link from a hub that turns on the feed shaft to
a bore the pick shaft turns in. The left one also holds the idler's shaft in a D-bore. Shown at
the stack the layout shows.
"""
function arm!(d::FeederDesign, b::Build, l::Layout, side; width = 9.0)
    u0, u1 = GEAR_PLANES.arm
    x0 = side > 0 ? d.inner_width / 2 + b.plate + u0 : left_x(d, b, u1)
    t = u1 - u0
    F, P = l.feed, l.pick
    centers = side > 0 ? [F, P] : [F, P, idler_center(l.gearbox, F, P)]
    pts = convex_hull(reduce(vcat, [circle_points(c, width; n = 32) for c in centers]))
    body = prism(pts, x0, t)
    body = cut!(body, cylinder_x(F, b.shaft / 2 + b.bore, x0 - 1, t + 2))
    body = cut!(body, cylinder_x(P, b.shaft / 2 + b.bore, x0 - 1, t + 2))
    side > 0 && return body
    I = idler_center(l.gearbox, F, P)
    return cut!(body, d_prism(I, b.shaft + 2b.grip, b.flat - b.grip, Vec2d(0, -1), x0 - 1, t + 2))
end

"""
The arm's idler: as wide as both cup gears' teeth it meshes, turning on its shaft.
"""
function idler!(d::FeederDesign, b::Build, l::Layout)
    g = l.gearbox
    u0, u1 = GEAR_PLANES.idler
    x1, x0 = left_x(d, b, u0), left_x(d, b, u1)
    I = idler_center(g, l.feed, l.pick)
    return gear!(I, g.idler, x0, x1 - x0; phase = gear_phases(g, l.feed, l.pick)[3], bore = b.shaft / 2 + b.bore)
end

"Profile point `s` along the tray from the ramp's foot and `n` above the tray surface."
along(l::Layout, s, n) = along(l.profile, s, n)

# --- the frame -------------------------------------------------------------------------------------

"x range of the right plate (motor side for feed and exit); the left plate is its mirror."
plate_x(d::FeederDesign, b::Build, side) = side > 0 ? (d.inner_width / 2, d.inner_width / 2 + b.plate) :
    (-d.inner_width / 2 - b.plate, -d.inner_width / 2)

"Length across x of parts that sit in the plates' pockets."
insert_span(d::FeederDesign, b::Build) = (-d.inner_width / 2 - b.pocket + b.slide, d.inner_width + 2 * (b.pocket - b.slide))

"""
Profile of the tray: a plate `thickness` under the tray surface from its back end to the ramp's
foot, and the ramp on its front end as a solid wedge up to the ramp's top edge.
"""
function tray_outline(p::Profile; thickness = 3.0)
    top = p.ramp.b
    depth = dot(Vec2d(top - p.foot), p.normal) + thickness
    return vcat([p.tray.a], points(p.fillet; step = 0.5), [top, top - depth * p.normal, p.tray.a - thickness * p.normal])
end

"""
Where the tray slides into the plates: a strip as tall as the ramp's front end along the whole
tray, open at the plates' rear edges, so the tray goes in from the back once the frame stands
and rests on the strip's lower face with its ramp against the front end.
"""
function tray_pocket_outline(p::Profile; thickness = 3.0)
    top = p.ramp.b
    depth = dot(Vec2d(top - p.foot), p.normal) + thickness
    return [p.tray.a - thickness * p.normal, top - depth * p.normal, top, p.tray.a + (depth - thickness) * p.normal]
end

"""
The inserts as profile solids across `x0 .. x0 + width`: electronics carrier, tray and both
guides. The plates cut them as pockets; the parts are the same shapes with the pocket clearance,
the tray's pocket the strip it slides along.
"""
function inserts!(d::FeederDesign, l::Layout, x0, width; grow = 0.0)
    p = l.profile
    g = d.guide_thickness + 2grow
    return vcat(
        prism(offset_polygon(carrier_outline(d, l), grow), x0, width),
        prism(offset_polygon(tray_pocket_outline(p), grow), x0, width),
        # Pockets grow at the guides' ends too, so a swollen guide does not butt against them.
        guide_solid(extend(offset(p.lower_guide, -grow), grow), g, 1, x0, width),
        guide_solid(extend(offset(p.upper_guide, grow), grow), g, -1, x0, width),
    )
end

"A convex polygon grown outward by `t` (each edge pushed out, corners mitered)."
function offset_polygon(pts::Vector{Point2d}, t)
    t == 0 && return pts
    n = length(pts)
    area = sum(cross(pts[i], pts[mod1(i + 1, n)]) for i in 1:n) / 2
    s = area > 0 ? 1 : -1                              # counterclockwise: outward is right of travel
    lines = [offset(Line(pts[i], pts[mod1(i + 1, n)]), s * t) for i in 1:n]
    return [intersection(lines[mod1(i - 1, n)], lines[i]) for i in 1:n]
end

"Square tie bar section around `c`, edges along the profile axes."
square(c::Point2d, a) = [c + Vec2d(-a / 2, -a / 2), c + Vec2d(a / 2, -a / 2), c + Vec2d(a / 2, a / 2), c + Vec2d(-a / 2, a / 2)]

"""
Outline of a slot along the circle of radius `R` about `c` from `p0` to `p1` (points on it),
`half` wide to each side, with round ends.
"""
function arc_slot(c::Point2d, R, p0::Point2d, p1::Point2d, half; n = 24)
    θ0, θ1 = atan(p0[2] - c[2], p0[1] - c[1]), atan(p1[2] - c[2], p1[1] - c[1])
    θ1 < θ0 && ((θ0, θ1) = (θ1, θ0))
    θ1 - θ0 > π && ((θ0, θ1) = (θ1, θ0 + 2π))
    polar(r, θ) = c + r * Vec2d(cos(θ), sin(θ))
    θs = range(θ0, θ1; length = n)
    ends(θ, from) = [polar(R, θ) + half * Vec2d(cos(φ), sin(φ)) for φ in range(from, from + π; length = 12)]
    return vcat([polar(R + half, θ) for θ in θs], ends(θ1, θ1)[2:(end - 1)], [polar(R - half, θ) for θ in reverse(θs)],
        ends(θ0, θ0 + π)[2:(end - 1)])
end

"The slot in both plates the pick shaft swings in, 1 mm clear of it."
pick_slot(d::FeederDesign, b::Build, l::Layout) = let s = swing_points(l.profile, d)
    arc_slot(l.feed, d.pick_arm, first(s), last(s), b.shaft / 2 + 1.0)
end

"""
    side_plate!(d, b, l, side)

One side plate. Feed and exit shafts turn in plain bores; the lower exit shaft rides in a slot so
it can drop; the pick shaft swings in an arc slot. Tray, guides and the electronics carrier sit
in pockets on the inner face; square tie bars pass through mortises and are wedged outside. The
plate stays behind the box wall up to its rim.
"""
function side_plate!(d::FeederDesign, b::Build, l::Layout, side)
    x0, x1 = plate_x(d, b, side)
    t = b.plate
    plate = prism(l.outline, x0, t)
    tools = Tuple{Int32, Int32}[]
    # Keep clear of the box: nothing in front of its back wall below the rim.
    front = -d.box_wall - 5.0
    append!(tools, box3((x0 - 1, front, -50.0), (t + 2, 400.0, d.box_height + 2 + 50.0)))
    r = b.shaft / 2 + b.bore
    for c in (l.feed, l.exit_up)
        append!(tools, cylinder_x(c, r, x0 - 1, t + 2))
    end
    append!(tools, prism(pick_slot(d, b, l), x0 - 1, t + 2))
    # The idler shaft rides in a slot: up to 1 mm above its resting place, `lift` below.
    slot = [l.exit_low + Vec2d(-r, -l.lift), l.exit_low + Vec2d(r, -l.lift), l.exit_low + Vec2d(r, 1.0), l.exit_low + Vec2d(-r, 1.0)]
    append!(tools, prism(slot, x0 - 1, t + 2))
    append!(tools, cylinder_x(l.exit_low + Vec2d(0, 1.0), r, x0 - 1, t + 2))
    append!(tools, cylinder_x(l.exit_low + Vec2d(0, -l.lift), r, x0 - 1, t + 2))
    for c in l.ties
        append!(tools, prism(square(c, b.tie + 2b.slide), x0 - 1, t + 2))
    end
    # Blind holes from the outer face: bracket pegs, motor lug pins, idler spring pegs.
    outer = side > 0 ? x1 : x0
    blind(c, r, depth) = cylinder_x(c, r, side > 0 ? outer - depth : outer - 1, depth + 1)
    if side < 0
        foreach(c -> append!(tools, blind(c, 3.05, 6.0)), gearbox_feet(l.gearbox))
    else
        foreach(c -> append!(tools, blind(c, LUG_PIN_HOLE / 2, 7.0)), byj48_holes(l.exit_up, l.exit_turn))
    end
    foreach(c -> append!(tools, blind(c, 2.55, 6.0)), idler_spring_pegs(l))
    for (s_, y, z) in cable_slots(d, l)
        s_ == side && append!(tools, box3((x0 - 1, y - CABLE_SLOT[1] / 2, z - CABLE_SLOT[2] / 2), (t + 2, CABLE_SLOT...)))
    end
    # Pockets on the inner face for the inserts.
    inner = side > 0 ? x0 - 1 : x1 - b.pocket
    append!(tools, inserts!(d, l, inner, b.pocket + 1; grow = b.slide))
    return cut!(plate, tools)
end

"x of the right fence's inner face: 1.5 mm beside the sheet."
fence_x(d::FeederDesign) = d.sheet_width / 2 + 1.5

"""
    tray!(d, b, l; fence = 15.0, thickness = 2.0)

The tray with the ramp on its front end and a fence along each side, `fence` high, that keeps the
stack in line; the fences end before the pick shaft's lowest swing. The middle of the ramp's top
edge is cut back for the pad head. It prints lying on its underside.
"""
function tray!(d::FeederDesign, b::Build, l::Layout; fence = 15.0, thickness = 2.0)
    p = l.profile
    x0, w = insert_span(d, b)
    body = prism(tray_outline(p), x0, w)
    reach = dot(Vec2d(first(swing_points(p, d)) - p.foot), p.down) - b.shaft / 2 - 6.0
    strip_ = [p.tray.a, along(p, reach, 0.0), along(p, reach, fence), p.tray.a + fence * p.normal]
    for x in (fence_x(d), -fence_x(d) - thickness)
        body = fuse!(body, prism([q - 0.5 * p.normal for q in strip_], x, thickness))
    end
    body = cut!(body, pad_room(d, l))
    return cut!(body, reduce(vcat, [leg_peg(d, l, x, TRAY_LEG.peg / 2 + 0.3, TRAY_LEG.peg_length + 0.3) for x in TRAY_LEG.pegs]))
end

"""
The stand under the tray's back end: `at` mm before it, `depth` deep along the tray, posts
`post` wide `inset` in from the plates' inner faces, bars `bar` high, and two pegs of `peg`
diameter and `peg_length` into blind holes in the tray's underside at x = `pegs`.
"""
const TRAY_LEG = (at = 25.0, depth = 8.0, foot = 40.0, post = 12.0, inset = 12.0, bar = 10.0, peg = 6.0, peg_length = 2.0, pegs = (-60.0, 60.0))

"A peg (or its hole) of radius `r` standing `h` into the tray's underside above the stand, at `x`."
function leg_peg(d::FeederDesign, l::Layout, x, r, h; thickness = 3.0)
    p = l.profile
    c = along(p, -d.tray_length + TRAY_LEG.at, -thickness)
    a, e = c - 1.0 * p.normal, c + h * p.normal
    return [(3, occ().addCylinder(x, a[1], a[2], 0.0, e[1] - a[1], e[2] - a[2], r))]
end

"""
    tray_leg!(d, b, l)

The stand under the tray's back end (`TRAY_LEG`): a frame across the tray of two posts from the
table to the tray's underside, a bar under the tray with two pegs into it and a foot bar on the
table, reaching toward the box so it stands. It prints lying on its back face.
"""
function tray_leg!(d::FeederDesign, b::Build, l::Layout; thickness = 3.0)
    p = l.profile
    t = TRAY_LEG
    c = along(p, -d.tray_length + t.at, -thickness)
    y0, y1 = c[1] - t.depth / 2, c[1] + t.depth / 2
    z0 = -d.box_wall
    zt = c[2] + 2.0                              # above the underside; cut to it below
    half = d.inner_width / 2 - t.inset
    body = box3((-half, y0, z0), (t.post, t.depth, zt - z0))
    body = fuse!(body, box3((half - t.post, y0, z0), (t.post, t.depth, zt - z0)))
    body = fuse!(body, box3((-half, y0, zt - t.bar - 2.0), (2half, t.depth, t.bar + 2.0)))
    body = fuse!(body, box3((-half, y0, z0), (2half, t.foot, t.bar)))             # toward the box, flush with the back face
    # Cut along the tray's underside.
    under = [along(p, -d.tray_length - 20, -thickness), along(p, 0.0, -thickness), along(p, 0.0, 60.0), along(p, -d.tray_length - 20, 60.0)]
    body = cut!(body, prism(under, -half - 1, 2half + 2))
    return fuse!(body, reduce(vcat, [leg_peg(d, l, x, t.peg / 2, t.peg_length) for x in t.pegs]))
end

"""
Room for the pad head and its leaf, cut from the tray's ramp and the lower guide's bed: the
head's width and 1 mm more on each side, everything within 1 mm of the pad's face and below.
"""
function pad_room(d::FeederDesign, l::Layout)
    p = l.profile
    half = d.pad_width / 2 + 1.0
    return cylinder_x(p.pad, d.pad_radius + 1.0, -half, 2half)
end

"Cuts 1 mm clearance around the feed and exit rollers out of a guide."
function clear_rollers!(g, d::FeederDesign, l::Layout, x0, w)
    for (c, r) in ((l.feed, d.feed_radius), (l.exit_low, d.exit_radius), (l.exit_up, d.exit_radius))
        g = cut!(g, cylinder_x(c, r + 1.0, x0 - 1, w + 2))
    end
    return g
end

"""
    lower_guide!(d, b, l, side)

One half of the lower guide, from the `side` plate's pocket to 0.25 mm short of the middle. The
pad sits in a gap cut from its bed; whole, the guide could not print standing on its end, the
bed beyond the gap would start in mid-air, so each half prints standing on its outer end.
"""
function lower_guide!(d::FeederDesign, b::Build, l::Layout, side)
    x0, w = insert_span(d, b)
    g = clear_rollers!(guide_solid(l.profile.lower_guide, d.guide_thickness, 1, x0, w), d, l, x0, w)
    g = cut!(g, pad_room(d, l))
    keep = side > 0 ? box3((0.25, -500.0, -100.0), (x0 + w, 1000.0, 400.0)) : box3((x0 - 1, -500.0, -100.0), (-x0 + 1 - 0.25, 1000.0, 400.0))
    return first(occ().intersect(g, keep))
end

function upper_guide!(d::FeederDesign, b::Build, l::Layout)
    x0, w = insert_span(d, b)
    return clear_rollers!(guide_solid(l.profile.upper_guide, d.guide_thickness, -1, x0, w), d, l, x0, w)
end

"""
    tie_bar!(d, b, l, c)

A square bar between the plates with tenons through both; a wedge through each tenon pulls
the plate against the bar's shoulder.
"""
function tie_bar!(d::FeederDesign, b::Build, c::Point2d)
    half = d.inner_width / 2
    a = b.tie
    reach = b.plate + b.tenon
    bar = prism(square(c, a), -half - reach, d.inner_width + 2reach)
    for side in (-1, 1)
        # Wedge slot just outside the plate, 0.5 mm into the plate so the wedge pulls it tight.
        xs = side > 0 ? half + b.plate - 0.5 : -half - b.plate + 0.5 - b.wedge
        append!(Tuple{Int32, Int32}[], Tuple{Int32, Int32}[])
        bar = cut!(bar, box3((xs, c[1] - a / 2 - 1, c[2] - a / 2 + 3), (b.wedge, a + 2, a - 6)))
    end
    return bar
end

"""
Wedge for a tie bar tenon, pushed in along +y. Its thickness along x tapers from 4 mm at the
head to 3 mm at the tip over 30 mm; the slot leaves 3.5 mm outside the plate, so the wedge
jams halfway, with its tip through the bar, and pulls the plate against the bar's shoulder.
Shown jammed.
"""
function wedge!(b::Build, c::Point2d, x0; length = 30.0)
    h = b.tie - 6 - 0.3
    y0 = c[1] - b.tie / 2 - length / 2                # the 3.5 mm point at the bar's near edge
    return [(3, occ().addWedge(x0, y0, c[2] - h / 2, b.wedge, length, h, -1, b.wedge - 1.0))]
end

# --- rollers -------------------------------------------------------------------------------------

"""
    ring_hub!(b, c, x0, length; radius, rings, cord = 2.5)

A roller hub for NBR O-rings: `rings` grooves so that the stretched rings stand out to
`radius`. The hub clamps on the D-shaft.
"""
function ring_hub!(b::Build, c::Point2d, x0, length; radius, rings, cord = 2.5, toward = Vec2d(0, -1))
    bottom = radius - cord + 0.3                     # groove bottom; 0.3 mm squeeze
    hub = sleeve!(b, c, bottom + 1.2, x0, length; toward)
    pitch = length / rings
    for k in 1:rings
        xc = x0 + (k - 0.5) * pitch
        groove = cut!(cylinder_x(c, bottom + 1.3, xc - cord / 2 - 0.1, cord + 0.2), cylinder_x(c, bottom, xc - cord / 2 - 1, cord + 2.2))
        hub = cut!(hub, groove)
    end
    return hub
end

"O-ring size that fits a hub: inner diameter stretched about 5 % onto the groove bottom."
oring_size(radius; cord = 2.5) = (inner = round(2 * (radius - cord + 0.3) / 1.05; digits = 1), cord = cord)

# --- motor mounts --------------------------------------------------------------------------------

"""
    motor_bracket!(b, c, plate_face, outward; turn, standoff, reach)

A table that holds a 28BYJ-48 `standoff` out from the plate face at x = `plate_face`, with room
for the gears between. Two legs, `reach` beyond the lug holes so they clear the gears, end in
pegs that press into the plate. It prints upside down, the motor face on the bed.
"""
function motor_bracket!(b::Build, c::Point2d, plate_face, outward; turn::Vec2d, standoff, reach, leg = 8.0, face = 3.0, peg = 6.0)
    m = BYJ48
    side = Vec2d(-turn[2], turn[1])
    h1, h2 = byj48_holes(c, turn)
    xf = outward > 0 ? plate_face + standoff - face : plate_face - standoff
    # Face plate: a bar under both lugs out to the legs, round in the middle around the motor's boss.
    bar = prism([h1 + (reach + leg / 2) * side + 5turn, h2 - (reach + leg / 2) * side + 5turn,
        h2 - (reach + leg / 2) * side - 5turn, h1 + (reach + leg / 2) * side - 5turn], xf, face)
    body = fuse!(bar, cylinder_x(c, 9.0, xf, face))
    body = cut!(body, cylinder_x(c, m.boss / 2 + 0.4, xf - 1, face + 2))
    for h in (h1, h2)
        body = cut!(body, cylinder_x(h, LUG_PIN_HOLE / 2, xf - 1, face + 2))         # lug pins, pressed in
    end
    xl = outward > 0 ? plate_face : xf + face
    len = standoff - face
    for foot in bracket_feet(c, turn; reach)
        body = fuse!(body, prism(square(foot, leg), xl, len))
        xp = outward > 0 ? plate_face - 5.0 : plate_face
        body = fuse!(body, cylinder_x(foot, peg / 2, xp, 5.0))
    end
    return body
end

"Where a bracket's legs stand: `reach` beyond the lug holes of a motor on `c`."
function bracket_feet(c::Point2d, turn::Vec2d; reach)
    h1, h2 = byj48_holes(c, turn)
    side = Vec2d(-turn[2], turn[1])
    return (h1 + reach * side, h2 - reach * side)
end

"""
Push pin through a motor lug into a bracket or plate: 3.2 mm shank, 7 mm head. The lug holes
are 4.0 mm (down to 3.85) and 35 ± 0.2 mm apart, so a swollen pin still passes when the holes
and the cooled plate's pins are apart by the most (`lug_check`); the shank presses into a
3.1 mm hole (`LUG_PIN_HOLE`). The boards' clamp frames use the same pegs and holes.
"""
function lug_pin!(c::Point2d, x0, outward; shank = 9.0)
    xh = outward > 0 ? x0 + shank : x0 - shank - 1.5
    xs = outward > 0 ? x0 : x0 - shank
    return fuse!(cylinder_x(c, LUG_PIN / 2, xs, shank), cylinder_x(c, 3.5, xh, 1.5))
end

"Lug pin shank and the hole it presses into, diameters in mm."
const LUG_PIN = 3.2
const LUG_PIN_HOLE = 3.1

# --- springs and the pad ------------------------------------------------------------------------

"The pad spring's leaf: PETG, printed lying on it."
const PAD_LEAF = Leaf(length = 32.0, thickness = 1.2, width = 30.0)

"""
The pad spring's design force, N. The spring prints lying on its leaf, so the leaf is six
0.2 mm layers thick; a first layer squeezed or left high by 0.05 mm changes its force by
−12 to +13 % (t³): 0.79 to 1.02 N. The roller drags the sheet over the pad with the pad's
friction times this force, and the exit roller pulls the tail through it; the separation itself
does not depend on it, both frictions grow with it (simulation: 0.8 to 1.0 N).
"""
const PAD_FORCE = 0.9

"""
The pad head's face along the nip, from `u0` before it to `u1` after it (mm), and the cork's
thickness. The ramp's top edge sits 0.3 mm outside the pad's face at about 9.8 mm before the
nip; the head stays 0.8 mm behind it.
"""
const PAD_HEAD = (u0 = -9.0, u1 = 6.0, cork = 2.0)

"Point on the pad's face circle (radius `r` about the pad center) above `u` along the nip."
function pad_face(p::Profile, d::FeederDesign, u, r)
    c = p.pad
    return c + u * p.entry + sqrt(r^2 - u^2) * left(p.entry)
end

"""
    pad_spring!(d, b, l; force, loaded = false)

Separation pad on a PETG leaf. The head's curved face carries a 2 mm cork strip; the leaf runs
back under the tray to its root block, which slides into the pad bar. Unloaded, the head stands
`deflection(force)` toward the roller; resting on it, the leaf bends back by that much, which
presses the pad with `force`. Variants for other forces differ only in the leaf's slope. Head
and root block end flush with the leaf's back face, so the spring prints lying on it: the leaf's
thickness is then six layers, which a swollen print does not change. With `loaded`, the part is
shown as it sits in the assembly (leaf approximated as straight).
"""
function pad_spring!(d::FeederDesign, b::Build, l::Layout; force, loaded = false)
    p = l.profile
    leaf = PAD_LEAF
    u0, u1 = l.pad_leaf
    D = l.pad_depth
    w, t = leaf.width, leaf.thickness
    lift = loaded ? 0.0 : deflection(leaf, force)          # head toward the roller
    up = lift * left(p.entry)
    # The head: its curved face from PAD_HEAD.u0 to u1, down to the leaf's back face.
    h = PAD_HEAD
    rc = d.pad_radius - h.cork
    arc = [pad_face(p, d, u, rc) for u in range(h.u0, h.u1; length = 16)]
    head = vcat(arc, [at_nip(p, h.u1, D + t / 2), at_nip(p, h.u0, D + t / 2)]) .+ Ref(up)
    body = prism(head, -w / 2, w)
    # The leaf from the head to the root block, straight when unloaded.
    a, c = at_nip(p, u0, D) + up, at_nip(p, u1, D)
    n = pad_back(p, a, c) * t / 2
    body = fuse!(body, prism([a + n, c + n, c - n, a - n], -w / 2, w))
    # The root block stands square to the nip; under it a wedge reaches down to the leaf's back
    # face, so the part lies flat on that face (the pad bar's pocket has room for the wedge).
    v = normalize(c - a)
    root = [c + n + 8v, c + n, at_nip(p, u1, D + t / 2 - 8), at_nip(p, u1 - 8, D + t / 2 - 8)]
    body = fuse!(body, prism(root, -w / 2, w))
    # Everything behind the leaf's back face goes: the part lies flat on it.
    f0, f1 = a + n - 80v, c + n + 80v
    body = cut!(body, prism([f0, f1, f1 + 40 * pad_back(p, a, c), f0 + 40 * pad_back(p, a, c)], -w / 2 - 1, w + 2))
    # Hole for the pin that holds the root block in the pad bar: the pin passes freely.
    return cut!(body, pad_pin_axis(p, l, LUG_PIN / 2 + 0.2))
end

"Unit normal of the pad leaf running from `a` to `c`, pointing away from the feed roller."
function pad_back(p::Profile, a::Point2d, c::Point2d)
    u = normalize(c - a)
    v = Vec2d(-u[2], u[1])
    return dot(v, left(p.entry)) < 0 ? v : -v
end

"The pin through the pad bar and the spring's root block, as a cylinder of radius `r` across the nip's direction."
function pad_pin_axis(p::Profile, l::Layout, r; half = 20.0)
    c = at_nip(p, l.pad_leaf[2] - 4, l.pad_depth)
    a, e = c - half * left(p.entry), c + half * left(p.entry)
    return [(3, occ().addCylinder(-1.0, a[1], a[2], 0.0, e[1] - a[1], e[2] - a[2], r))]
end

"""
    pad_bar!(d, b, l)

The tie bar that carries the pad spring: a pocket the spring's root block slides into from the
leaf's side, 0.6 mm deeper below for the wedge under the block, and a hole for the pin that
holds it.
"""
function pad_bar!(d::FeederDesign, b::Build, l::Layout)
    p = l.profile
    bar = tie_bar!(d, b, l.pad_bar)
    u1 = l.pad_leaf[2]
    D, t = l.pad_depth, PAD_LEAF.thickness
    g = b.slide
    w = PAD_LEAF.width
    pocket = [at_nip(p, u1 - 8 - g, D + t / 2 + g + 0.6), at_nip(p, u1 + b.tie, D + t / 2 + g + 0.6), at_nip(p, u1 + b.tie, D + t / 2 - 8 - g),
        at_nip(p, u1 - 8 - g, D + t / 2 - 8 - g)]
    bar = cut!(bar, prism(pocket, -w / 2 - g, w + 2g))
    return cut!(bar, pad_pin_axis(p, l, LUG_PIN_HOLE / 2))                 # the pin presses in, as the lug pins do
end

# --- upper exit roller springs ---------------------------------------------------------------------

"Leaf spring of the lower exit roller (idler): 40 mm long, 8 mm wide, 2.6 mm thick PETG."
const IDLER_LEAF = Leaf(length = 40.0, thickness = 2.6, width = 8.0)

"""
    idler_spring!(d, b, l, side; force, loaded)

A leaf on the outside of a side plate pushing the lower exit shaft's journal up against the
driven roller. Its root block has two pegs into the plate. Unloaded, the tip reaches
`deflection(force)` above the journal's underside.
"""
function idler_spring!(d::FeederDesign, b::Build, l::Layout, side; force = 1.5, loaded = false)
    x0, x1 = plate_x(d, b, side)
    face = side > 0 ? x1 : x0
    leaf = IDLER_LEAF
    w, t = leaf.width, leaf.thickness
    bottom = l.exit_low[2] - b.shaft / 2           # journal underside with the roller resting
    δ = loaded ? 0.0 : deflection(leaf, force)
    tip = Point2d(l.exit_low[1] + 4.0, bottom + δ - t / 2)
    root = Point2d(l.exit_low[1] - leaf.length, bottom - t / 2)
    xs = side > 0 ? face + 1.0 : face - 1.0 - w
    u = normalize(tip - root)
    n = Vec2d(-u[2], u[1]) * t / 2
    body = prism([root + n, tip + n, tip - n, root - n], xs, w)
    # The block reaches 2 mm below the lower peg, so the peg rises from the block, not from the air.
    block = [root + Vec2d(-12, -10.5), root + Vec2d(0, -10.5), root + Vec2d(0, t / 2), root + Vec2d(-12, t / 2)]
    xb = side > 0 ? face : face - w - 1.0
    body = fuse!(body, prism(block, xb, w + 1.0))
    for c in idler_spring_pegs(l)
        xp = side > 0 ? face - 5.0 : face
        body = fuse!(body, cylinder_x(c, 2.5, xp, 5.0))
    end
    return body
end

"Where the idler springs' pegs go into the plates."
function idler_spring_pegs(l::Layout)
    y = l.exit_low[1] - IDLER_LEAF.length - 6
    z = l.exit_low[2] - 5.0 - IDLER_LEAF.thickness / 2
    return (Point2d(y, z - 2.0), Point2d(y + 0.0, z - 6.5))
end

# --- tolerance coupon and electronics tray -------------------------------------------------------

"""
    coupon!(b; origin)

A 20-minute test print to check the fits before the real parts: shaft holes with the design's
radial clearance `b.bore` and 0.1 mm less and more, pocket slots for the 2 mm guides with
`b.slide` and 0.1 mm less and more, lug
pin holes of 3.8, 3.9 and 4.0 mm, and three sockets for the 28BYJ-48 shaft (the design's
`b.socket` play, then 0.1 and 0.2 mm more; the snug one that still goes on is right). Print it with the
`coupon_shaft` and try which fit turns, slides or holds.
"""
function coupon!(b::Build; origin = Point2d(0, 0), x0 = 0.0, thickness = 8.0)
    w, h = 90.0, 30.0
    o = origin
    body = prism([o, o + Vec2d(w, 0), o + Vec2d(w, h), o + Vec2d(0, h)], x0, thickness)
    for (k, c) in enumerate(b.bore .+ (-0.1, 0.0, 0.1))
        body = cut!(body, cylinder_x(o + Vec2d(10 + 14(k - 1), 10), b.shaft / 2 + c, x0 - 1, thickness + 2))
    end
    for (k, c) in enumerate(b.slide .+ (-0.1, 0.0, 0.1))
        y = 48 + 6(k - 1)
        body = cut!(body, prism([o + Vec2d(y, 4), o + Vec2d(y + 2 + 2c, 4), o + Vec2d(y + 2 + 2c, 26), o + Vec2d(y, 26)],
            x0 + thickness - b.pocket, b.pocket + 1))
    end
    # Holes for the lug pins and the board clamps' pegs: the design's and 0.1 mm either way.
    for (k, dia) in enumerate(LUG_PIN_HOLE .+ (-0.1, 0.0, 0.1))
        body = cut!(body, cylinder_x(o + Vec2d(10 + 12(k - 1), 23), dia / 2, x0 - 1, thickness + 2))
    end
    # Three sockets for the 28BYJ-48's shaft, with the design's play and 0.1 and 0.2 mm more.
    for (k, play) in enumerate(b.socket .+ (0.0, 0.1, 0.2))
        # The motor's face against the coupon's top: the socket from there down through the coupon.
        body = cut!(body, motor_socket(o + Vec2d(80, 7 + 8(k - 1)), x0 + thickness + BYJ48.boss_height, -1; play))
    end
    return body
end

"A 50 mm piece of D-shaft, a 2 mm test strip and a lug pin for the coupon."
function coupon_shaft!(b::Build; origin = Point2d(0, -20), x0 = 0.0)
    s = shaft!(b, origin, x0, x0 + 50)
    bottom = -(b.shaft / 2 - b.flat)                     # the shaft lies on its flat; the strip and the pin stand beside it
    strip2 = prism([origin + Vec2d(10, bottom), origin + Vec2d(12, bottom), origin + Vec2d(12, bottom + 10), origin + Vec2d(10, bottom + 10)], x0, 22.0)
    z = origin[2] + bottom
    pin = fuse!(cylinder_z(x0 + 35, origin[1] + 12, z, 1.5, 3.5), cylinder_z(x0 + 35, origin[1] + 12, z + 1.49, 7.01, LUG_PIN / 2))
    return vcat(s, strip2, pin)
end

# --- electronics carrier -------------------------------------------------------------------------

"A cylinder along z: center (x, y), from z0 up by h."
cylinder_z(x, y, z0, h, r) = [(3, occ().addCylinder(x, y, z0, 0, 0, h, r))]

"""
The bought boards on the electronics carrier, as their listings and product photos give them:
the PCB's size (x, y) and how far it may differ, the height of the corner shelves it rests on,
the corner zones (x, y) on top and below where there is nothing but the corner holes (the
clamp's fingers and the shelves stay inside them), and where its center is: `x`, and `dy` from
the carrier's middle. `hole` is a corner hole's center, in x and y from the board's corner,
and its radius.

- ULN2003 driver (ANGEEK ZC-A0591): 35.5 × 31.4 mm per the listing; holes in all four corners,
  the motor socket at least 3.4 mm in from the edges, the nearest solder joints 5 mm. Solder
  side 2.5 mm deep, so both rest 4 mm up, toward the box, near their motors' cable slots.
- ESP32 DevKit (MiMiU, 30 pin, USB-C, CP2102): 28.4 × 51.3 mm, measured on the listing's
  straight top photo against the 2.54 mm pin pitch: header rows 25.4 mm apart, first pin 10 mm
  from the USB end, the EN and BOOT buttons 4.4 mm in from the long edges, the USB-C socket
  2.1 mm past the end, holes in all four corners. Its header pins point down; jumper housings
  (2.5 + 14 mm) and the wires' bends need 23 mm, so it rests 24 mm up, USB end to the back (−y).
"""
const BOARDS = (
    (name = "uln2003_drive", x = -84.0, dy = 14.0, size = (35.5, 31.4), spread = (0.3, 0.3), shelf = 4.0, clear = (top = (3.0, 3.0), bottom = (4.0, 4.0)), hole = (2.75, 2.5, 1.6), usb = false),
    (name = "esp32", x = -35.0, dy = -6.0, size = (28.4, 51.3), spread = (0.3, 0.6), shelf = 24.0, clear = (top = (4.0, 8.0), bottom = (8.0, 4.0)), hole = (2.3, 2.55, 1.5), usb = true),
    (name = "uln2003_exit", x = 84.0, dy = 19.0, size = (35.5, 31.4), spread = (0.3, 0.3), shelf = 4.0, clear = (top = (3.0, 3.0), bottom = (4.0, 4.0)), hole = (2.75, 2.5, 1.6), usb = false),
)

"""
How the boards are held, in mm: `fit` is the play per side around the largest board; each
corner has a post `post` square outside the pocket's side along x and a `wall` thick end wall
reaching `leg` along the pocket's end; shelves reach `shelf` under each corner; the clamp frame stands `lift`
above the nominal board, is `frame` thick, and its fingers reach `finger` (x, y) over the corners;
its pegs (`LUG_PIN`, `peg` long) press into `hole` deep holes in the posts.
"""
const HOLDER = (fit = 0.15, post = 6.5, wall = 2.0, leg = 4.0, shelf = 3.0, lift = 0.4, frame = 2.4,
    finger = Dict("uln2003" => (2.4, 2.4), "esp32" => (2.6, 3.0)), peg = 3.5, hole = 4.0, pcb = 1.6)

finger_reach(bd) = HOLDER.finger[startswith(bd.name, "uln") ? "uln2003" : "esp32"]

"""
    board_frame(d, l, bd)

Where a board's holder is: its pocket's half sizes, the pocket's center, the shelf top and the
posts' top (where the clamp frame's underside lies), and the four corners as (corner, (sx, sy)).
"""
function board_frame(d::FeederDesign, l::Layout, bd)
    c = carrier_span(d, l)
    hx = (bd.size[1] + 2bd.spread[1]) / 2 + HOLDER.fit
    hy = (bd.size[2] + 2bd.spread[2]) / 2 + HOLDER.fit
    center = Point2d(bd.x, c.y + bd.dy)
    shelf = c.top + bd.shelf
    corners = [(center + Vec2d(sx * hx, sy * hy), (sx, sy)) for sx in (-1, 1) for sy in (-1, 1)]
    return (hx = hx, hy = hy, center = center, shelf = shelf, top = shelf + HOLDER.pcb + HOLDER.lift, corners = corners)
end

"Peg hole centers of a board's holder: in the middle of each corner post."
holder_pegs(f) = [P + Vec2d(sx * HOLDER.post / 2, -sy * HOLDER.post / 2) for (P, (sx, sy)) in f.corners]

"An axis-aligned box from corner `a` to corner `b` (any order), z from z0 to z1."
function span_box(a::Point2d, b::Point2d, z0, z1)
    lo, hi = min.(a, b), max.(a, b)
    return box3((lo[1], lo[2], z0), (hi[1] - lo[1], hi[2] - lo[2], z1 - z0))
end

"""
    carrier_span(d)

Where the electronics carrier lies: a 2.4 mm plate between the side plates, low enough that
the ESP32 on its stand stays under the pad bar, behind the box and above the lower tie bars.
Returns its y range, its underside z and the y of the boards' centers.
"""
function carrier_span(d::FeederDesign; z0 = 22.0, thickness = 2.4, length = 76.0)
    y1 = -d.box_wall - 5.0 - 6.0
    y0 = y1 - length
    return (y0 = y0, y1 = y1, z0 = z0, top = z0 + thickness, y = (y0 + y1) / 2)
end
carrier_span(d::FeederDesign, l::Layout) = carrier_span(d)

carrier_outline(d::FeederDesign, l::Layout) = let c = carrier_span(d, l)
    [Point2d(c.y0, c.z0), Point2d(c.y1, c.z0), Point2d(c.y1, c.top), Point2d(c.y0, c.top)]
end

"""
    electronics_carrier!(d, b, l)

Plate that carries the two ULN2003 driver boards and the ESP32. It sits in pockets of both side
plates like the tray. The boards' hole patterns are not published, so each board lies in a
pocket of four corner posts, on shelves under its corners (where only its corner holes are),
and a clamp frame pressed onto the posts holds it down by the corners (`board_clamp!`).
Everything rises from the plate, so it prints flat.
"""
function electronics_carrier!(d::FeederDesign, b::Build, l::Layout)
    c = carrier_span(d, l)
    h = HOLDER
    body = prism(carrier_outline(d, l), insert_span(d, b)...)
    for bd in BOARDS
        f = board_frame(d, l, bd)
        for (P, (sx, sy)) in f.corners
            z0 = c.top - 0.01
            body = fuse!(body, span_box(P, P - Vec2d(sx * h.shelf, sy * h.shelf), z0, f.shelf))                    # shelf
            body = fuse!(body, span_box(P, P + Vec2d(sx * h.post, -sy * h.post), z0, f.top))                       # post beside the board
            body = fuse!(body, span_box(P - Vec2d(sx * h.leg, 0), P + Vec2d(sx * h.post, sy * h.wall), z0, f.top))  # end wall
        end
        for q in holder_pegs(f)
            body = cut!(body, cylinder_z(q[1], q[2], f.top - h.hole, h.hole + 1, LUG_PIN_HOLE / 2))
        end
    end
    return body
end

"""
    board_clamp!(d, l, bd)

Frame that holds a board down: a ring around the pocket on the posts' tops with a finger over
each of the board's corners and a peg into each post. The ESP32's is open at the USB end for
the plug. It prints upside down, flat on its top.
"""
function board_clamp!(d::FeederDesign, l::Layout, bd)
    h = HOLDER
    f = board_frame(d, l, bd)
    fx, fy = finger_reach(bd)
    z0, z1 = f.top, f.top + h.frame
    C = f.center
    ring = span_box(C - Vec2d(f.hx + h.post, f.hy + h.wall), C + Vec2d(f.hx + h.post, f.hy + h.wall), z0, z1)
    ring = cut!(ring, span_box(C - Vec2d(f.hx, f.hy), C + Vec2d(f.hx, f.hy), z0 - 1, z1 + 1))
    if bd.usb
        ring = cut!(ring, span_box(C + Vec2d(-f.hx + h.leg, -f.hy + 0.01), C + Vec2d(f.hx - h.leg, -f.hy - h.wall - 1), z0 - 1, z1 + 1))
    end
    for (P, (sx, sy)) in f.corners
        ring = fuse!(ring, span_box(P, P - Vec2d(sx * fx, sy * fy), z0, z1))
    end
    for q in holder_pegs(f)
        ring = fuse!(ring, cylinder_z(q[1], q[2], z0 - h.peg, h.peg + 0.01, LUG_PIN / 2))
    end
    return ring
end

"""
    board!(d, l, bd; size = bd.size, at = Vec2d(0, 0))

A board as bought, for clearance checks and renders: the PCB of `size` moved by `at` in its
pocket, the parts on top and, for the ESP32, the USB-C socket and the jumper housings on its
downward header pins.
"""
function board!(d::FeederDesign, l::Layout, bd; size = bd.size, at = Vec2d(0, 0))
    f = board_frame(d, l, bd)
    sx, sy = size
    C = f.center + at
    z = f.shelf
    pcb = span_box(C - Vec2d(sx / 2, sy / 2), C + Vec2d(sx / 2, sy / 2), z, z + HOLDER.pcb)
    top = z + HOLDER.pcb
    if !bd.usb
        return fuse!(pcb, span_box(C - Vec2d(sx / 2 - 4, sy / 2 - 4), C + Vec2d(sx / 2 - 4, sy / 2 - 4), top - 0.01, top + 11.0))
    end
    pcb = fuse!(pcb, span_box(C - Vec2d(sx / 2 - 5, sy / 2 - 9), C + Vec2d(sx / 2 - 5, sy / 2 - 1), top - 0.01, top + 3.2))
    pcb = fuse!(pcb, span_box(C + Vec2d(-4.5, -sy / 2 - 2.1), C + Vec2d(4.5, -sy / 2 + 7.5), top - 0.01, top + 3.2))   # USB-C socket
    for side in (-1, 1)                                   # header rows with jumper housings below
        x = C[1] + side * (sx / 2 - 1.45)
        pcb = fuse!(pcb, span_box(Point2d(x - 1.27, C[2] - sy / 2 + 8.8), Point2d(x + 1.27, C[2] - sy / 2 + 46.8), z - 16.5, z + 0.01))
    end
    return pcb
end

"""
    board_envelopes(d, l, bd; size, at)

Room each board needs that no printed part may take, for `electronics_check`: above a driver
(25 mm, for the motor plug, the jumper wires on its pins and their bends) and under it (solder
side, 2.5 mm) everywhere but its corner zones; above the ESP32 (6 mm, buttons and socket) but its
corner zones, under it its two header rows with the jumper housings and 6 mm for the wires to
bend, and behind it the USB-C plug (14 × 8 mm, 30 mm long) and its cable.
"""
function board_envelopes(d::FeederDesign, l::Layout, bd; size = bd.size, at = Vec2d(0, 0))
    f = board_frame(d, l, bd)
    sx, sy = size
    C = f.center + at
    z, top = f.shelf, f.shelf + HOLDER.pcb
    # The board's footprint without its corner zones: a cross of two boxes.
    cross((cx, cy), z0, z1) = vcat(span_box(C - Vec2d(sx / 2 - cx, sy / 2), C + Vec2d(sx / 2 - cx, sy / 2), z0, z1),
        span_box(C - Vec2d(sx / 2, sy / 2 - cy), C + Vec2d(sx / 2, sy / 2 - cy), z0, z1))
    if !bd.usb
        return vcat(cross(bd.clear.top, top + 0.01, top + 25.0), cross(bd.clear.bottom, z - 2.5, z - 0.01))
    end
    out = cross(bd.clear.top, top + 0.01, top + 6.0)
    for side in (-1, 1)
        x = C[1] + side * (sx / 2 - 1.45)
        append!(out, span_box(Point2d(x - 1.4, C[2] - sy / 2 + 8.6), Point2d(x + 1.4, C[2] - sy / 2 + 47.0), z - 16.5 - 6.0, z - 0.01))
    end
    socket = C[2] - sy / 2 - 2.1
    zc = top + 1.6
    append!(out, span_box(Point2d(C[1] - 7.0, socket - 30.0), Point2d(C[1] + 7.0, socket - 0.01), zc - 4.0, zc + 4.0))
    append!(out, span_box(Point2d(C[1] - 2.5, socket - 70.0), Point2d(C[1] + 2.5, socket - 30.0), zc - 2.5, zc + 2.5))
    return out
end

"""
Slots in the side plates that the motors' 5-pin plugs (JST XHP-5, 14.9 × 5.8 mm) pass through
to their drivers inside: (side, y, z) of each slot's center, below the gears and the idler
spring, above the drivers (`slot_check`). `CABLE_SLOT` is the slot's size (y, z).
"""
function cable_slots(d::FeederDesign, l::Layout)
    return ((-1, -34.0, 50.0), (1, -19.0, 50.0))
end
const CABLE_SLOT = (18.0, 10.0)
const XHP5 = (14.9, 5.8)

"""
    cable_routes(d, b, l)

Each motor's lead as laid: out of its cable housing (17.1 mm from the body's axis, 3.5 mm behind
the mounting face), 3 mm on in the same direction where it bends, straight back to its plate,
`off` mm off the plate's outer face (over the tenons and wedges, which stand out 6 mm) to the
cable slot, through it, and to the farthest top corner of its driver board (where the socket
may be). A motor that sits on its plate is in the way: its lead first goes beside its body. The
drive motor's lead cannot reach its plate past the gears: it goes back behind the motor's body and
lugs, down to the slot's height and straight in. Returns per motor its name, its driver and the
route's points (x, y, z).
"""
function cable_routes(d::FeederDesign, b::Build, l::Layout; off = 14.0)
    W2, o = d.inner_width / 2, d.inner_width / 2 + b.plate
    g = l.gearbox
    mface = -(o + GEAR_PLANES.face)
    # Each motor's mounting face and the way its body points along x.
    motors = (("drive", g.motor, g.turn, mface, -1, "uln2003_drive"), ("exit", l.exit_up, l.exit_turn, o, 1, "uln2003_exit"))
    map(zip(motors, cable_slots(d, l))) do ((name, shaft, turn, mf, out, board), (side, y, z))
        x = mf + out * BYJ48.cable_exit
        exit = shaft + (BYJ48.offset + BYJ48.cable_box[2]) * turn
        bend = exit + 3.0 * turn
        bd = only(filter(q -> q.name == board, collect(BOARDS)))
        f = board_frame(d, l, bd)
        slot_in = Vec3d(side * W2, y, z)
        far = argmax(q -> norm(q - slot_in), [Vec3d(f.center[1] + kx * bd.size[1] / 2, f.center[2] + ky * bd.size[2] / 2,
            f.shelf + HOLDER.pcb + 10.0) for kx in (-1, 1), ky in (-1, 1)])
        if name == "drive"
            # Out beyond the bracket, the gears are in the way: the lead goes back past the motor's
            # body, down to the slot's height and straight in.
            body = shaft + BYJ48.offset * turn
            lugs = [body + s * (BYJ48.holes / 2 + BYJ48.lug_width / 2) * Vec2d(-turn[2], turn[1]) for s in (-1, 1)]
            behind = min(bend[1], body[1] - BYJ48.body / 2, minimum(first, lugs)) - 7.0       # clear of body, lugs and pin heads
            pts = [Vec3d(x, exit[1], exit[2]), Vec3d(x, bend[1], bend[2]), Vec3d(x, behind, bend[2]), Vec3d(x, behind, z),
                Vec3d(x, y, z), Vec3d(side * o, y, z), slot_in, far]
            return (motor = name, board = board, points = pts)
        end
        face = side * (o + off)
        around = Vec3d[]
        if min(mf, mf + out * BYJ48.depth) <= face <= max(mf, mf + out * BYJ48.depth)      # the face route passes the body
            body = shaft + BYJ48.offset * turn
            across = Vec2d(-turn[2], turn[1])
            s = sign(dot(Point2d(y, z) - body, across))
            q = bend + s * (BYJ48.body / 2 + 5.0) * across
            push!(around, Vec3d(face, q[1], q[2]))
        end
        pts = vcat([Vec3d(x, exit[1], exit[2]), Vec3d(x, bend[1], bend[2]), Vec3d(face, bend[1], bend[2])], around,
            [Vec3d(face, y, z), Vec3d(side * o, y, z), slot_in, far])
        (motor = name, board = board, points = pts)
    end
end

"""
    cable_check(d, b, l; lead = BYJ48.lead)

Length of each motor's lead along `cable_routes` with 20 mm slack, against the shortest lead the
two drawings allow (Rajguru 230 ± 10 mm).
"""
function cable_check(d::FeederDesign, b::Build, l::Layout; lead = BYJ48.lead, slack = 20.0)
    map(cable_routes(d, b, l)) do r
        len = sum(norm(r.points[k + 1] - r.points[k]) for k in 1:(length(r.points) - 1)) + slack
        (motor = r.motor, length = round(len), lead = lead, fits = len <= lead)
    end
end
