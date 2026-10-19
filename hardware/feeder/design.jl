# The feeder's dimensions and the side profile derived from them. Both the simulation and the
# CAD parts are built from the same profile, so a changed dimension changes both.

"""
    FeederDesign(; kwargs...)

All dimensions of the sheet feeder, in millimeters and degrees.

The side profile lives in the y-z plane: y points from the feeder toward the output box,
z points up and x runs across the sheet. The inner face of the box's back wall is at y = 0,
the box floor at z = 0.

The sheets lie face up in a tray behind the box that rises toward the back by `tray_angle`,
little enough that friction holds the stack where it lies: its weight stays on the tray.
Their leading edges touch a ramp that rises from the tray to above the thickest stack. A pick
roller rests by its own weight on the top sheet and pushes it over the ramp's top edge onto the
separation pad, a wide curve of cork that leads it at a flat angle into the nip under the feed
roller: a sheet pushed between two rollers stays nearly straight, so the nip has to open the
way it comes. Sheets dragged along under it stop on the pad. The pick roller hangs on an arm
that swings about the feed roller's shaft, so the gears that drive it stay in mesh at any stack
height; the arm is short, so the sheet has little room to buckle between the two rollers.
Behind the nip the sheet runs over a gentle hump to the exit rollers, which push it flat into
the box, still face up: the top sheet goes first.
"""
Base.@kwdef struct FeederDesign
    sheet_length::Float64 = 297.0       # A4, fed short edge first
    sheet_width::Float64 = 210.0
    tray_angle::Float64 = 10.0          # the tray rises toward the back; friction holds the stack
    tray_length::Float64 = 300.0
    stack_height::Float64 = 4.0         # thickest stack: 40 sheets of 80 g/m²
    nip_height::Float64 = 8.0           # separation nip above the tray surface, over the thickest stack
    entry_angle::Float64 = 10.0         # the nip's direction against the tray surface
    ramp_angle::Float64 = 35.0          # ramp against the tray surface
    ramp_top::Float64 = 5.0             # the ramp's top edge above the tray surface: above the thickest stack
    foot_radius::Float64 = 5.0          # the corner between tray and ramp is rounded: a crease cannot wedge into it
    pick_arm::Float64 = 30.0            # from the feed roller's axis to the pick roller's: the pick shaft passes outside
                                        # the feed roller's gear
    feed_radius::Float64 = 12.0
    pick_radius::Float64 = 12.0
    roller_width::Float64 = 30.0        # pick and feed roller
    pad_radius::Float64 = 30.0          # curved face of the separation pad
    pad_width::Float64 = 30.0
    guide_gap::Float64 = 3.0
    guide_start::Float64 = 8.0          # the guides begin this far behind the nip
    after_nip::Float64 = 10.0           # straight path behind the nip
    turn_radius::Float64 = 60.0         # the hump between the nip and the exit
    before_exit::Float64 = 20.0         # straight guide between the hump and the exit rollers
    exit_radius::Float64 = 12.0
    exit_height::Float64 = 88.0         # exit nip above the box floor
    exit_ahead::Float64 = 30.0          # exit nip in front of the box's back wall, so the tail drops inside
    exit_tilt::Float64 = 14.0           # degrees the sheet leaves the exit nip downward (negative: upward, the lower
                                        # roller sits in front of the nip)
    box_length::Float64 = 320.0         # inside, along y; A4 needs room to slide past the back wall
    box_width::Float64 = 225.0          # inside, along x
    box_height::Float64 = 60.0
    box_wall::Float64 = 3.0
    inner_width::Float64 = 222.0        # clear width between the side frames
    guide_thickness::Float64 = 2.0
    camera_height::Float64 = 340.0      # phone lens above the box floor
end

"A straight piece of a guide or wall in the side profile."
struct Line
    a::Point2d
    b::Point2d
end

"""
A circular piece of a guide, counterclockwise from `start` to `stop` (radians). `inside` tells
whether the sheet runs inside the circle (the guide curves around the sheet) or outside it.
"""
struct Arc
    center::Point2d
    radius::Float64
    start::Float64
    stop::Float64
    inside::Bool
end

points(l::Line; step = 2.0) = [l.a, l.b]
function points(a::Arc; step = 2.0)
    n = max(2, ceil(Int, a.radius * (a.stop - a.start) / step) + 1)
    return [a.center + a.radius * Vec2d(cos(φ), sin(φ)) for φ in range(a.start, a.stop; length = n)]
end
points(pieces::Vector; step = 2.0) = reduce(vcat, [points(p; step) for p in pieces])

"""
    Profile(design)

Key points and surfaces of the feeder's side profile, in millimeters.

`down` points along the tray toward the ramp (the way the top sheet leaves the stack),
`normal` from the tray surface into the stack, `entry` along the nip. `along(p, s, n)` is the
point `s` along the tray from the ramp's foot and `n` above the tray surface. The ramp's top
edge sits just above the pad's face, so heads step down onto the pad. The pick roller's arm
swings about the feed roller's axis (`pick_center`).
"""
struct Profile
    down::Vec2d
    normal::Vec2d
    ramp_dir::Vec2d          # along the ramp, up from the tray
    entry::Vec2d             # along the nip, the way the sheet goes
    foot::Point2d            # where the ramp leaves the tray surface
    nip::Point2d             # separation nip
    feed::Point2d            # feed roller center, above the nip
    pad::Point2d             # pad face center below the nip, resting on the feed roller
    turn_center::Point2d
    exit::Point2d            # exit nip
    exit_low::Point2d        # idler roller center
    exit_up::Point2d         # driven exit roller center
    tray::Line               # tray surface, from its back end to the rounded foot
    fillet::Arc              # the rounded corner between tray and ramp
    ramp::Line               # from the rounded foot up to its top edge at the pad
    lower_guide::Vector{Union{Line, Arc}}   # under the sheet from the ramp's top to the exit, beside the pad around the nip
    upper_guide::Vector{Union{Line, Arc}}   # over it
    box::Vector{Line}        # inner faces: back wall, floor, front wall
    path::Vector{Point2d}    # sheet centerline from the nip to the exit
end

"How far into a circle of `radius` a chord sits whose ends lie `depth` inside it: half its length."
chord(radius, depth) = sqrt(radius^2 - (radius - depth)^2)

"Point `s` along the tray from the ramp's foot and `n` above the tray surface."
along(p::Profile, s, n) = p.foot + s * p.down + n * p.normal

"Where the rounded foot or the ramp is `h` above the tray surface, as `s` along the tray from the foot."
function ramp_at(p::Profile, h)
    c, r = p.fillet.center, p.fillet.radius
    hc = dot(Vec2d(c - p.foot), p.normal)                 # the rounding's center height: r
    sc = dot(Vec2d(c - p.foot), p.down)
    top = dot(Vec2d(p.ramp.a - p.foot), p.normal)
    h <= top && return sc + sqrt(max(r^2 - (hc - h)^2, 0.0))
    return dot(Vec2d(p.ramp.a - p.foot), p.down) + (h - top) * dot(p.ramp_dir, p.down) / dot(p.ramp_dir, p.normal)
end

"Unit vector `v` turned a quarter counterclockwise."
left(v::Vec2d) = Vec2d(-v[2], v[1])

function Profile(d::FeederDesign)
    θ = deg2rad(d.tray_angle)
    down = Vec2d(cos(θ), -sin(θ))             # toward the box, descending
    normal = Vec2d(sin(θ), cos(θ))
    β = deg2rad(d.ramp_angle)
    ramp_dir = cos(β) * down + sin(β) * normal
    α = deg2rad(d.exit_tilt)
    out = Vec2d(cos(α), -sin(α))               # direction the sheet leaves the exit nip
    up = Vec2d(sin(α), cos(α))                 # from the exit nip to the driven roller's center
    h = d.guide_gap / 2

    ε = deg2rad(d.entry_angle)
    entry = cos(ε) * down + sin(ε) * normal

    # Back from the exit: straight, the turn from the nip's direction to `out` (down over a hump,
    # or up through a dip), straight along the nip's direction to the nip. `side` is +1 where
    # the turn's center lies left of the path (a turn up), -1 right of it.
    exit = Point2d(d.exit_ahead, d.exit_height)
    side = cross(entry, out) > 0 ? 1 : -1
    turn_end = exit - d.before_exit * out
    turn_center = turn_end + side * d.turn_radius * up
    turn_start = turn_center - side * d.turn_radius * left(entry)
    nip = turn_start - d.after_nip * entry
    feed = nip + d.feed_radius * left(entry)
    pad = nip - d.pad_radius * left(entry)

    # The tray surface lies `nip_height` below the nip. The ramp's top edge is 0.3 mm outside the
    # pad's face, `ramp_top` above the tray, upstream of the nip.
    base = nip - d.nip_height * normal
    cs, cn = dot(pad - base, down), dot(pad - base, normal)
    top = base + (cs - sqrt((d.pad_radius + 0.3)^2 - (d.ramp_top - cn)^2)) * down + d.ramp_top * normal
    foot = top - d.ramp_top / sin(β) * ramp_dir
    # The rounding touches tray and ramp `t` from where they would meet.
    r = d.foot_radius
    t = r * tan(β / 2)
    center = foot - t * down + r * normal
    angle_to(q) = atan(q[2] - center[2], q[1] - center[1])
    fillet = Arc(center, r, angle_to(foot - t * down), angle_to(foot + t * ramp_dir), true)
    tray = Line(foot - d.tray_length * down, foot - t * down)
    ramp = Line(foot + t * ramp_dir, top)

    # The turn's arc counterclockwise from φa to φb, at radius R + δ (δ: toward the upper guide's side).
    φs = atan((turn_start - turn_center)[2], (turn_start - turn_center)[1])
    φe = atan((turn_end - turn_center)[2], (turn_end - turn_center)[1])
    φa, φb = side > 0 ? (φs, φe) : (φe, φs)
    turn(δ) = Arc(turn_center, d.turn_radius - side * δ, φa, φb, side * δ < 0)
    c = d.guide_start
    # Beside the pad the lower guide starts as its bed: 0.5 mm inside the pad's face from 1 mm
    # past the ramp's top edge until it is `h` below the nip, where its straight part begins.
    rb = d.pad_radius - 0.5
    join = pad + (d.pad_radius - h) * left(entry) + sqrt(rb^2 - (d.pad_radius - h)^2) * entry
    angle(q) = atan(q[2] - pad[2], q[1] - pad[1])
    lower_guide = Union{Line, Arc}[
        Arc(pad, rb, angle(join), angle(top + 1.0 * entry), false),
        Line(join, turn_start - h * left(entry)),
        turn(-h),
        Line(turn_end - h * up, exit - (chord(d.exit_radius, h) + 1) * out - h * up),
    ]
    upper_guide = Union{Line, Arc}[
        Line(nip + c * entry + h * left(entry), turn_start + h * left(entry)),
        turn(h),
        Line(turn_end + h * up, exit - (chord(d.exit_radius, h) + 1) * out + h * up),
    ]

    L, H = d.box_length, d.box_height
    box = [Line(Point2d(0, H), Point2d(0, 0)), Line(Point2d(0, 0), Point2d(L, 0)), Line(Point2d(L, 0), Point2d(L, H))]
    arc = points(Arc(turn_center, d.turn_radius, φa, φb, true))
    path = vcat([nip], side > 0 ? arc : reverse(arc), [exit])

    return Profile(down, normal, ramp_dir, entry, foot, nip, feed, pad, turn_center, exit,
        exit - d.exit_radius * up, exit + d.exit_radius * up, tray, fillet, ramp, lower_guide, upper_guide, box, path)
end

"""
    pick_center(p, d, height)

Center of the pick roller resting on a stack `height` mm thick: where its arm's circle about
the feed roller's axis is `pick_radius` above the stack's top, behind the feed roller.
"""
function pick_center(p::Profile, d::FeederDesign, height)
    R = d.pick_arm
    level = d.pick_radius + height                 # center's height above the tray surface
    dn = level - dot(Vec2d(p.feed - p.foot), p.normal)
    abs(dn) <= R || error("the pick arm cannot reach a stack $height mm thick")
    return p.feed + dn * p.normal - sqrt(R^2 - dn^2) * p.down
end

"Unit vector along which the pick roller rises off a stack `height` mm thick: its arm's swing."
function pick_lift(p::Profile, d::FeederDesign, height)
    t = left(normalize(Vec2d(pick_center(p, d, height) - p.feed)))
    return dot(t, p.normal) > 0 ? t : -t
end

"Length of the sheet path from the nip to the exit nip, in millimeters."
function path_length(d::FeederDesign)
    r = Profile(d).entry
    return d.after_nip + d.turn_radius * abs(atan(r[2], r[1]) + deg2rad(d.exit_tilt)) + d.before_exit
end
