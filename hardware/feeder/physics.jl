# 2D side-view physics of paper sheets among guides, rollers and pads. Units are SI.
#
# A sheet is a chain of nodes a few millimeters apart. Stretching is implicit: every step, one
# tridiagonal solve per sheet finds the segment tensions, so paper keeps its real axial
# stiffness at any step size. Bending, gravity, air drag and contacts are explicit.
#
# Contacts are penalty springs. Friction is a tangential spring capped by Coulomb's law
# (Cundall & Strack), so a sheet really sticks until the static limit is exceeded instead of
# creeping. Convex things (rollers, edges, the inside of a bend) are tested against the sheet's
# segments, flat and concave surfaces against its nodes: a chain of straight segments cuts
# corners on anything convex.

"""
    Paper(; kwargs...)

One sheet, by default 80 g/m² office paper fed short edge first. `bending` is the stiffness
E·I and `stretch` the stiffness E·A of the whole sheet width (E ≈ 4 GPa, t = 0.1 mm,
w = 210 mm).
"""
Base.@kwdef struct Paper
    length::Float64 = 0.297
    width::Float64 = 0.210
    thickness::Float64 = 1.0e-4
    grammage::Float64 = 0.080
    bending::Float64 = 7.0e-5
    stretch::Float64 = 8.4e4
    segment::Float64 = 2.0e-3
end

"""
    Shape(; kwargs...)

What a sheet's past left in it. `curl` is the radius it relaxes to, `Inf` for a flat sheet. A
sheet that was folded and opened again keeps a kink at each of its `creases`: (distance from the
leading edge in m, angle in rad, positive turning counterclockwise walking from the leading edge
to the tail); the broken fibers make the crease a hinge with `hinge` times the paper's bending
stiffness. `waves` makes cockled paper wavy along the sheet: (height from trough to crest in m,
wavelength in m).
"""
Base.@kwdef struct Shape
    curl::Float64 = Inf
    creases::Vector{Tuple{Float64, Float64}} = Tuple{Float64, Float64}[]
    hinge::Float64 = 0.2
    waves::Tuple{Float64, Float64} = (0.0, 0.04)
end

crease_node(p::Paper, at) = clamp(round(Int, at / spacing(p)) + 1, 2, node_count(p) - 1)

"""
    rest_angles(paper, shape)

The angle each node of a sheet turns to when nothing pushes on it, from its leading edge to its
tail: curl, waves (the curvature of a sine) and creases.
"""
function rest_angles(p::Paper, sh::Shape)
    ds = spacing(p)
    a, λ = sh.waves
    θ = [(isinf(sh.curl) ? 0.0 : ds / sh.curl) + a / 2 * (2π / λ)^2 * sin(2π * (j - 1) * ds / λ) * ds for j in 1:node_count(p)]
    for (at, angle) in sh.creases
        θ[crease_node(p, at)] += angle
    end
    return θ
end

"Bending stiffness at each node of a sheet relative to the paper's: lower at its creases."
function stiffness(p::Paper, sh::Shape)
    k = ones(node_count(p))
    for (at, _) in sh.creases
        k[crease_node(p, at)] = sh.hinge
    end
    return k
end

node_count(p::Paper) = round(Int, p.length / p.segment) + 1
spacing(p::Paper) = p.length / (node_count(p) - 1)

"Static and sliding friction coefficient of a surface against paper."
struct Friction
    static::Float64
    kinetic::Float64
end
Friction(μ::Real) = Friction(μ, μ)

Base.@kwdef struct ContactModel
    stiffness::Float64 = 1.0e5      # N/m per contact
    damping::Float64 = 1.0          # N·s/m; a node can sit in four contacts, so keep 4·damping·dt/mass well below 2
    tangential::Float64 = 0.5       # tangential spring relative to `stiffness`
end

# --- obstacles -----------------------------------------------------------------------------

"""
Flat static surface; the sheet's nodes touch it from either side. A `floor` only has a side to
the left of `a` to `b`: what lies under it is solid (paper in a pile), and a node that got below
it is pushed back up, not further down.
"""
struct Wall
    a::Vec2d
    b::Vec2d
    friction::Friction
    floor::Bool
end
Wall(a, b, friction; floor = false) = Wall(a, b, friction, floor)

"Static edge, such as the free end of a guide; the sheet's segments touch it."
struct Corner
    p::Vec2d
    friction::Friction
end

"Circular guide with the sheet inside the circle; the sheet's nodes touch it."
struct ConcaveArc
    center::Vec2d
    radius::Float64
    start::Float64
    stop::Float64
    friction::Friction
end

"Circular guide with the sheet outside the circle; the sheet's segments touch it."
struct ConvexArc
    center::Vec2d
    radius::Float64
    start::Float64
    stop::Float64
    friction::Friction
end

"""
A stepper motor geared to one or more rollers, all at the same surface speed. It holds the
commanded surface speed `drive` as long as the rollers need at most `force` in total at their
surfaces; beyond that it falls behind, as a real stepper loses steps. Running, the firmware
commands `speed`. `travel` is how far the commanded speed has moved the surface, which is what
the firmware counts in steps.
"""
mutable struct Motor
    const name::Symbol
    const force::Float64
    const speed::Float64
    drive::Float64
    travel::Float64
    need::Float64
    peak::Float64               # largest total force it gave
end
Motor(name, force; speed = 0.0) = Motor(name, force, speed, 0.0, 0.0, 0.0, 0.0)

"""
A roller, or a pad's rounded face. It may slide along `axis` away from `home` against a spring
with force `preload` at `lift = 0` and stiffness `rate`. A roller turns in its feeding sense
`spin` (+1 counterclockwise, -1 clockwise); a pad has `spin = 0` and does not turn.

A roller's surface speed `speed` (feeding sense) is a state: contacts, bearing `drag` and its
`motor` act on its rotational `inertia` (I/r², in kg). With `oneway`, a freewheel between motor
and roller lets the roller run ahead of the motor but never brakes it; while it runs ahead,
the freewheel's pawl drags with `clutch` (N at the surface). With `rectified`, two freewheels
driven in opposite senses turn the roller forward whichever way the motor runs; one of them
always runs backward under the pawl. Gears may turn the roller at `ratio` times its motor's
speed and lose part of the motor's work (`efficiency`); the motor's force is counted at the
speed it is commanded at. Without a motor the roller is an idler.
"""
mutable struct Roller
    const name::Symbol
    const home::Vec2d
    const axis::Vec2d
    const radius::Float64
    const mass::Float64
    const preload::Float64
    const rate::Float64
    const spin::Float64
    const friction::Friction
    const inertia::Float64
    const drag::Float64
    const motor::Union{Motor, Nothing}
    const oneway::Bool
    const clutch::Float64
    const rectified::Bool
    const ratio::Float64
    const efficiency::Float64
    lift::Float64
    lift_rate::Float64
    speed::Float64
    angle::Float64
    force::Vec2d
    torque::Float64
    given::Float64              # N at the surface from the motor in the last step
end

function Roller(name, home, radius, friction; axis = Vec2d(0, 0), mass = 0.01, preload = 0.0, rate = 0.0, spin = 0.0,
        inertia = 0.005, drag = 0.0, motor = nothing, oneway = false, clutch = 0.0, rectified = false, ratio = 1.0, efficiency = 1.0)
    return Roller(name, home, axis, radius, mass, preload, rate, spin, friction, inertia, drag, motor, oneway, clutch, rectified, ratio, efficiency,
        0.0, 0.0, 0.0, 0.0, zero(Vec2d), 0.0, 0.0)
end

center(r::Roller) = r.home + r.lift * r.axis
omega(r::Roller) = r.spin * r.speed / r.radius

within(φ, start, stop) = mod(φ - start, 2π) <= mod(stop - start, 2π)
within(a::Union{ConcaveArc, ConvexArc}, r::Vec2d) = within(atan(r[2], r[1]), a.start, a.stop)

"Closest point on segment `a`-`b` to `p`, and its parameter along the segment."
function closest(a::Vec2d, b::Vec2d, p::Vec2d)
    ab = b - a
    u = clamp(dot(p - a, ab) / dot(ab, ab), 0.0, 1.0)
    return a + u * ab, u
end

perp(v::Vec2d) = Vec2d(-v[2], v[1])

# Node probes return (distance from the surface, unit normal from the surface to the node).
function probe(w::Wall, p::Vec2d)
    q, _ = closest(w.a, w.b, p)
    r = p - q
    if w.floor
        n = normalize(perp(w.b - w.a))
        return dot(r, n), n
    end
    d = norm(r)
    return d, r / d
end

function probe(c::ConcaveArc, p::Vec2d)
    r = p - c.center
    d = norm(r)
    within(c, r) || return Inf, zero(Vec2d)
    return c.radius - d, -r / d
end

# Segment probes return (distance, unit normal from the obstacle to the sheet, segment parameter).
function probe(c::Corner, a::Vec2d, b::Vec2d)
    q, u = closest(a, b, c.p)
    r = q - c.p
    d = norm(r)
    return d, r / d, u
end

function probe(c::ConvexArc, a::Vec2d, b::Vec2d)
    q, u = closest(a, b, c.center)
    r = q - c.center
    d = norm(r)
    within(c, r) || return Inf, zero(Vec2d), u
    return d - c.radius, r / d, u
end

function probe(r::Roller, a::Vec2d, b::Vec2d)
    q, u = closest(a, b, center(r))
    v = q - center(r)
    d = norm(v)
    return d - r.radius, v / d, u
end

surface_velocity(::Union{Wall, Corner, ConcaveArc, ConvexArc}, n::Vec2d) = zero(Vec2d)
surface_velocity(r::Roller, n::Vec2d) = r.lift_rate * r.axis + omega(r) * r.radius * perp(n)

friction(o) = o.friction

bounds(w::Wall) = (min.(w.a, w.b), max.(w.a, w.b))
bounds(c::Corner) = (c.p, c.p)
bounds(a::Union{ConcaveArc, ConvexArc}) = (a.center .- a.radius, a.center .+ a.radius)

"""
Uniform grid over static obstacles so that each node or segment only tests the few obstacles
near it.
"""
struct ObstacleGrid
    origin::Vec2d
    cell::Float64
    cells::Matrix{Vector{Int}}
end

function ObstacleGrid(obstacles::Vector, margin; cell = 0.005)
    isempty(obstacles) && return ObstacleGrid(zero(Vec2d), cell, Matrix{Vector{Int}}(undef, 0, 0))
    lo = reduce((a, o) -> min.(a, bounds(o)[1]), obstacles; init = Vec2d(Inf, Inf)) .- 2margin
    hi = reduce((a, o) -> max.(a, bounds(o)[2]), obstacles; init = Vec2d(-Inf, -Inf)) .+ 2margin
    dims = Tuple(ceil.(Int, (hi - lo) ./ cell) .+ 1)
    cells = [Int[] for _ in 1:dims[1], _ in 1:dims[2]]
    for (k, o) in enumerate(obstacles)
        a, b = bounds(o)
        i0, j0 = floor.(Int, (a .- margin .- lo) ./ cell) .+ 1
        i1, j1 = floor.(Int, (b .+ margin .- lo) ./ cell) .+ 1
        for i in max(i0, 1):min(i1, dims[1]), j in max(j0, 1):min(j1, dims[2])
            push!(cells[i, j], k)
        end
    end
    return ObstacleGrid(lo, cell, cells)
end

const NO_OBSTACLES = Int[]

function nearby(g::ObstacleGrid, p::Vec2d)
    i, j = floor.(Int, (p - g.origin) ./ g.cell) .+ 1
    (1 <= i <= size(g.cells, 1) && 1 <= j <= size(g.cells, 2)) || return NO_OBSTACLES
    return g.cells[i, j]
end

"""
Contact memory for one kind of contact: the tangential spring of each (sheet element,
obstacle) pair and the step it was last in contact. A spring that was not in contact in the
previous step starts from zero.
"""
struct ContactMemory
    spring::Matrix{Float64}
    seen::Matrix{Int}
end
ContactMemory(n, m) = ContactMemory(zeros(n, m), fill(-2, n, m))

spring(c::ContactMemory, i, k, step) = c.seen[i, k] == step - 1 ? c.spring[i, k] : 0.0
function remember!(c::ContactMemory, i, k, step, ξ)
    c.spring[i, k] = ξ
    c.seen[i, k] = step
    return
end

"""
    contact_force(model, friction, depth, normal, vrel, ξ, dt)

Penalty contact with sticking Coulomb friction. `normal` points from the obstacle toward the
sheet, `vrel` is the sheet's velocity relative to the obstacle's surface and `ξ` the tangential
spring from the previous step. Returns the force on the sheet and the new spring.
"""
function contact_force(m::ContactModel, fr::Friction, depth, n::Vec2d, vrel::Vec2d, ξ, dt)
    fn = m.stiffness * depth - m.damping * dot(vrel, n)
    fn <= 0 && return zero(Vec2d), 0.0
    t = perp(n)
    vt = dot(vrel, t)
    ξ += vt * dt
    kt = m.tangential * m.stiffness
    ft = -kt * ξ - m.damping * vt
    if abs(ft) > fr.static * fn
        s = ξ == 0 ? sign(vt) : sign(ξ)
        ft = -s * fr.kinetic * fn
        ξ = s * fr.kinetic * fn / kt
    end
    return fn * n + ft * t, ξ
end

"""
Sheets that are not simulated, such as the rest of a stack, pressing on simulated sheet
`sheet` with `pressure` normal to a tray, plus a concentrated force `press` (a pressure
wheel, which can be lifted off) at `press_at`. They do not move, so they hold the sheet back
with paper friction. Positions along the tray are measured upward from `origin`.
"""
mutable struct StackLoad
    const sheet::Int
    const pressure::Float64
    press::Float64
    const press_at::Float64
    const press_width::Float64
    const origin::Vec2d
    const down::Vec2d
    const normal::Vec2d
    const from::Float64
    const to::Float64
    const reach::Float64      # only nodes this close to the tray belong to the stack
    const friction::Friction
end

no_load() = StackLoad(0, 0.0, 0.0, 0.0, 1.0, zero(Vec2d), Vec2d(1, 0), Vec2d(0, 1), 0.0, 0.0, 0.0, Friction(0.0))

# --- the world ---------------------------------------------------------------------------------

"""
    World(sheets, walls, concave, corners, convex, rollers; paper, kwargs...)

Sheets, given as node polylines from leading to trailing edge, among static obstacles and
rollers. Sheet k+1 must lie on the face side (left of the direction toward the leading edge)
of sheet k: each node only looks for contacts on the sheet below and above it. Sheet k has the
shape `shapes[k]`, the shapes repeating if there are fewer than sheets.
"""
mutable struct World
    const paper::Paper
    const contact::ContactModel
    const paper_paper::Friction
    const gravity::Vec2d
    const air_density::Float64
    const drag::Float64
    const dt::Float64
    const x::Vector{Vec2d}
    const v::Vector{Vec2d}
    const f::Vector{Vec2d}
    const mass::Vector{Float64}
    const rest_angle::Vector{Float64}
    const hinge::Vector{Float64}            # bending stiffness at each node relative to the paper's
    const tension::Vector{Float64}          # N, tension of the segment starting at each node
    const sheets::Int
    const nodes::Int
    const walls::Vector{Wall}
    const concave::Vector{ConcaveArc}
    const corners::Vector{Corner}
    const convex::Vector{ConvexArc}
    const rollers::Vector{Roller}
    const motors::Vector{Motor}
    const node_grid::ObstacleGrid           # walls, then concave arcs
    const segment_grid::ObstacleGrid        # corners, then convex arcs
    const load::StackLoad
    const wall_memory::ContactMemory
    const concave_memory::ContactMemory
    const corner_memory::ContactMemory
    const convex_memory::ContactMemory
    const roller_memory::ContactMemory
    const sheet_memory::ContactMemory       # columns: sheet below, sheet above
    const load_memory::ContactMemory
    const hint::Matrix{Int}                 # closest segment on the sheet below / above
    const scratch::NTuple{5, Vector{Float64}}
    const directions::Vector{Vec2d}
    t::Float64
    step::Int
end

function World(sheets::Vector{Vector{Vec2d}}, walls, concave, corners, convex, rollers;
        paper = Paper(), shapes = [Shape()], contact = ContactModel(), paper_paper = Friction(0.45, 0.38),
        gravity = Vec2d(0, -9.81), air_density = 1.2, drag = 1.5, dt = 5.0e-6, load = no_load())
    n = node_count(paper)
    all(s -> length(s) == n, sheets) || error("every sheet needs $n nodes")
    x = reduce(vcat, sheets)
    N = length(x)
    ds = spacing(paper)
    # Every node carries one segment's worth of paper, the end nodes too: halving them would
    # make the ends the stiffest spot of the explicit integration for a 0.7 % mass error.
    mass = fill(paper.grammage * paper.width * ds, N)
    shape(k) = shapes[mod1(k, length(shapes))]
    rest_angle = reduce(vcat, [rest_angles(paper, shape(k)) for k in eachindex(sheets)])
    hinge = reduce(vcat, [stiffness(paper, shape(k)) for k in eachindex(sheets)])
    node_grid = ObstacleGrid(vcat(walls, concave), 2.0e-3)
    segment_grid = ObstacleGrid(vcat(corners, convex), ds + 2.0e-3)
    w = World(paper, contact, paper_paper, gravity, air_density, drag, dt, x, zeros(Vec2d, N), zeros(Vec2d, N),
        mass, rest_angle, hinge, zeros(N), length(sheets), n, walls, concave, corners, convex, rollers,
        unique(Motor[r.motor for r in rollers if r.motor !== nothing]), node_grid, segment_grid,
        load, ContactMemory(N, length(walls)), ContactMemory(N, length(concave)), ContactMemory(N, length(corners)),
        ContactMemory(N, length(convex)), ContactMemory(N, length(rollers)), ContactMemory(N, 2), ContactMemory(N, 1),
        ones(Int, N, 2), ntuple(_ -> zeros(N), 5), zeros(Vec2d, N), 0.0, 0)
    find_neighbors!(w)
    return w
end

sheet_nodes(w::World, k) = ((k - 1) * w.nodes + 1):(k * w.nodes)
sheet_points(w::World, k) = w.x[sheet_nodes(w, k)]

# --- forces ------------------------------------------------------------------------------------

"Gravity, air drag and bending of every sheet. Stretching is handled implicitly in `stretch!`."
function sheet_forces!(w::World)
    (; x, v, f, mass) = w
    ds = spacing(w.paper)
    kb = w.paper.bending / ds
    cb = 0.02 * kb * sqrt(mass[1] * ds^2 / kb)
    drag = 0.5 * w.air_density * w.drag * w.paper.width * ds
    for i in eachindex(x)
        f[i] = mass[i] * w.gravity
    end
    for k in 1:w.sheets
        r = sheet_nodes(w, k)
        for i in (first(r) + 1):(last(r) - 1)
            e1 = x[i] - x[i - 1]
            e2 = x[i + 1] - x[i]
            θ = atan(cross(e1, e2), dot(e1, e2))
            g0 = perp(e1) / dot(e1, e1)
            g2 = perp(e2) / dot(e2, e2)
            g1 = -g0 - g2
            rate = dot(g0, v[i - 1]) + dot(g1, v[i]) + dot(g2, v[i + 1])
            moment = kb * w.hinge[i] * (θ - w.rest_angle[i]) + cb * rate
            f[i - 1] -= moment * g0
            f[i] -= moment * g1
            f[i + 1] -= moment * g2
        end
        for i in r
            a = x[max(i - 1, first(r))]
            b = x[min(i + 1, last(r))]
            n = perp(normalize(b - a))
            vn = dot(v[i], n)
            f[i] -= drag * abs(vn) * vn * n
        end
    end
    return
end

"Nodes against walls and concave arcs."
function node_contacts!(w::World)
    half = w.paper.thickness / 2
    nw = length(w.walls)
    for i in eachindex(w.x)
        for k in nearby(w.node_grid, w.x[i])
            if k <= nw
                node_contact!(w, i, w.walls[k], w.wall_memory, k, half)
            else
                node_contact!(w, i, w.concave[k - nw], w.concave_memory, k - nw, half)
            end
        end
    end
    return
end

function node_contact!(w::World, i, o, memory::ContactMemory, k, half)
    d, n = probe(o, w.x[i])
    depth = half - d
    (depth > 0 && depth < 4half) || return
    F, ξ = contact_force(w.contact, friction(o), depth, n, w.v[i] - surface_velocity(o, n), spring(memory, i, k, w.step), w.dt)
    w.f[i] += F
    remember!(memory, i, k, w.step, ξ)
    return
end

"Segments against corners, convex arcs and rollers. The force acts at the closest point."
function segment_contacts!(w::World)
    half = w.paper.thickness / 2
    nc = length(w.corners)
    x = w.x
    for k in 1:w.sheets
        r = sheet_nodes(w, k)
        for i in first(r):(last(r) - 1)
            mid = (x[i] + x[i + 1]) / 2
            for c in nearby(w.segment_grid, mid)
                if c <= nc
                    segment_contact!(w, i, w.corners[c], w.corner_memory, c, half)
                else
                    segment_contact!(w, i, w.convex[c - nc], w.convex_memory, c - nc, half)
                end
            end
            for (c, roller) in enumerate(w.rollers)
                norm(mid - center(roller)) < roller.radius + 0.01 || continue
                segment_contact!(w, i, roller, w.roller_memory, c, half)
            end
        end
    end
    return
end

function segment_contact!(w::World, i, o, memory::ContactMemory, k, half)
    (; x, v, f) = w
    d, n, u = probe(o, x[i], x[i + 1])
    depth = half - d
    (depth > 0 && depth < 4half) || return
    vp = (1 - u) * v[i] + u * v[i + 1]
    F, ξ = contact_force(w.contact, friction(o), depth, n, vp - surface_velocity(o, n), spring(memory, i, k, w.step), w.dt)
    f[i] += (1 - u) * F
    f[i + 1] += u * F
    react!(o, F, n)
    remember!(memory, i, k, w.step, ξ)
    return
end

react!(o, F, n) = nothing
function react!(r::Roller, F, n)
    r.force -= F
    r.torque += cross(r.radius * n, -F)     # the force on the roller acts at its surface
    return
end

"Face normal of segment `j`: the side that faces the next sheet up the stack."
face(x, j) = normalize(perp(x[j] - x[j + 1]))

"Closest segment of sheet `other` to node `i`, by searching all of it."
function closest_segment(w::World, i, other)
    r = sheet_nodes(w, other)
    best, dist = first(r), Inf
    for j in first(r):(last(r) - 1)
        q, _ = closest(w.x[j], w.x[j + 1], w.x[i])
        dq = norm(w.x[i] - q)
        dq < dist && ((best, dist) = (j, dq))
    end
    return best
end

function find_neighbors!(w::World)
    for k in 1:w.sheets, i in sheet_nodes(w, k), (side, other) in ((1, k - 1), (2, k + 1))
        1 <= other <= w.sheets || continue
        w.hint[i, side] = closest_segment(w, i, other)
    end
    return
end

"Walk from the remembered segment to the locally closest one."
function walk(w::World, i, j, other)
    r = sheet_nodes(w, other)
    lo, hi = first(r), last(r) - 1
    j = clamp(j, lo, hi)
    x = w.x
    dist(j) = norm(x[i] - first(closest(x[j], x[j + 1], x[i])))
    dj = dist(j)
    while j > lo && (dn = dist(j - 1)) < dj
        j, dj = j - 1, dn
    end
    while j < hi && (dn = dist(j + 1)) < dj
        j, dj = j + 1, dn
    end
    return j
end

"""
Contacts between neighboring sheets. Sheet k+1 always lies on the face side of sheet k, in
the tray, in the guides and on the pile, so each node only looks at the sheet below and the
sheet above it.
"""
function sheet_contacts!(w::World)
    (; x, v, f, step) = w
    t = w.paper.thickness
    refresh = step % 200 == 0
    for k in 1:w.sheets, (side, other) in ((1, k - 1), (2, k + 1))
        1 <= other <= w.sheets || continue
        for i in sheet_nodes(w, k)
            if refresh && w.sheet_memory.seen[i, side] < step - 1
                w.hint[i, side] = closest_segment(w, i, other)
            end
            j = walk(w, i, w.hint[i, side], other)
            w.hint[i, side] = j
            q, u = closest(x[j], x[j + 1], x[i])
            n = face(x, j)
            h = dot(x[i] - q, n)
            # Only nodes over the segment itself, not beyond its ends.
            norm(x[i] - q - h * n) < 1.0e-4 || continue
            side == 2 && (n = -n; h = -h)
            depth = t - h
            (depth > 0 && depth < 2t) || continue
            vq = (1 - u) * v[j] + u * v[j + 1]
            F, ξ = contact_force(w.contact, w.paper_paper, depth, n, v[i] - vq, spring(w.sheet_memory, i, side, step), w.dt)
            f[i] += F
            f[j] -= (1 - u) * F
            f[j + 1] -= u * F
            remember!(w.sheet_memory, i, side, step, ξ)
        end
    end
    return
end

"The unsimulated sheets and the pressure wheel press on their simulated neighbor."
function stack_load!(w::World)
    L = w.load
    L.sheet == 0 && return
    (; x, v, f, step) = w
    ds = spacing(w.paper)
    area = w.paper.width * ds
    kt = w.contact.tangential * w.contact.stiffness
    for i in sheet_nodes(w, L.sheet)
        r = x[i] - L.origin
        up = -dot(r, L.down)
        (L.from <= up <= L.to && dot(r, L.normal) < L.reach) || continue
        fn = L.pressure * area + (abs(up - L.press_at) <= L.press_width / 2 ? L.press * ds / L.press_width : 0.0)
        fn > 0 || continue
        vt = dot(v[i], L.down)
        ξ = spring(w.load_memory, i, 1, step) + vt * w.dt
        ft = -kt * ξ - w.contact.damping * vt
        if abs(ft) > L.friction.static * fn
            s = sign(ξ)
            ft = -s * L.friction.kinetic * fn
            ξ = s * L.friction.kinetic * fn / kt
        end
        f[i] += -fn * L.normal + ft * L.down
        remember!(w.load_memory, i, 1, step, ξ)
    end
    return
end

"""
Implicit stretching (backward Euler, linearized along the current segment directions): the
tension impulse λ of every segment makes its tension after the step equal to its stiffness
times its stretch. Per sheet this is a symmetric, diagonally dominant tridiagonal system.
"""
function stretch!(w::World)
    (; x, v, mass, dt) = w
    ds = spacing(w.paper)
    k = w.paper.stretch / ds
    β = dt^2 * k
    diag, upper, rhs, cp, dp = w.scratch
    u = w.directions
    for s in 1:w.sheets
        r = sheet_nodes(w, s)
        i0, i1 = first(r), last(r) - 1        # segment i joins node i and i + 1
        for i in i0:i1
            e = x[i + 1] - x[i]
            l = norm(e)
            u[i] = e / l
            rhs[i] = dt * k * (l - ds) + β * dot(u[i], v[i + 1] - v[i])
            diag[i] = 1 + β * (1 / mass[i] + 1 / mass[i + 1])
        end
        for i in i0:(i1 - 1)
            upper[i] = -β * dot(u[i], u[i + 1]) / mass[i + 1]   # also the lower entry of row i + 1
        end
        cp[i0] = i0 < i1 ? upper[i0] / diag[i0] : 0.0
        dp[i0] = rhs[i0] / diag[i0]
        for i in (i0 + 1):i1
            den = diag[i] - upper[i - 1] * cp[i - 1]
            cp[i] = i < i1 ? upper[i] / den : 0.0
            dp[i] = (rhs[i] - upper[i - 1] * dp[i - 1]) / den
        end
        λ = dp[i1]
        w.tension[i1] = λ / dt
        for i in (i1 - 1):-1:i0
            λ = dp[i] - cp[i] * λ
            w.tension[i] = λ / dt
        end
        for i in i0:i1
            J = w.tension[i] * dt * u[i]
            v[i] += J / mass[i]
            v[i + 1] -= J / mass[i + 1]
        end
    end
    return
end

"Surface speeds the motor gives the roller's freewheel inputs: one, or two opposite ones behind a rectifier."
cups(r::Roller) = r.rectified ? (r.ratio * r.motor.drive, -r.ratio * r.motor.drive) : (r.ratio * r.motor.drive,)

"Pawl drag of the freewheels the roller runs ahead of, at its surface."
function clutch_drag(r::Roller)
    (r.oneway && r.motor !== nothing) || return 0.0
    return sum(c -> r.clutch * clamp((r.speed - c) / 1.0e-3, 0.0, 1.0), cups(r))
end

"""
What a freewheel the motor turns backward costs the motor: the pawl drags the cup forward, against
the motor.
"""
function back_drag(r::Roller)
    (r.oneway && r.motor !== nothing) || return 0.0
    return sum(c -> r.clutch * clamp((r.speed - c) / 1.0e-3, 0.0, 1.0) * clamp(-c / 1.0e-3, 0.0, 1.0), cups(r))
end

"Force from contacts, bearing drag and freewheel drag on a roller's surface, in its feeding sense."
load(r::Roller) = r.spin * r.torque / r.radius - r.drag * clamp(r.speed / 1.0e-3, -1.0, 1.0) - clutch_drag(r)

"""
What the motor would have to give `r` to keep it at the speed of its fastest input after this
step: never negative behind a freewheel.
"""
function need(r::Roller, dt)
    n = r.inertia * (maximum(cups(r)) - r.speed) / dt - load(r)
    return r.oneway ? max(n, 0.0) : n
end

"""
Turns the rollers: every motor shares its force limit among its rollers in proportion to what
each needs, then each roller's speed follows from its load and motor force.
"""
function turn!(rollers::Vector{Roller}, dt)
    for r in rollers
        r.motor === nothing || (r.motor.need = 0.0)
    end
    for r in rollers
        r.motor === nothing && continue
        r.given = need(r, dt)
        r.motor.need += r.ratio * (abs(r.given) + back_drag(r)) / r.efficiency
    end
    for r in rollers
        r.spin == 0 && continue
        if r.motor === nothing
            r.given = 0.0
        else
            m = r.motor
            m.need > m.force && (r.given *= m.force / m.need)
        end
        r.speed += dt * (load(r) + r.given) / r.inertia
    end
    return
end

function integrate!(w::World)
    (; x, v, f, mass, dt) = w
    for i in eachindex(x)
        v[i] += dt * f[i] / mass[i]
    end
    stretch!(w)
    for i in eachindex(x)
        x[i] += dt * v[i]
    end
    for r in w.rollers
        if r.axis != zero(Vec2d)
            push = dot(r.force, r.axis) - r.preload - r.rate * r.lift - 2 * sqrt(w.contact.stiffness * r.mass) * r.lift_rate
            r.lift_rate += dt * push / r.mass
            r.lift += dt * r.lift_rate
            if r.lift < 0
                r.lift = 0.0
                r.lift_rate = max(r.lift_rate, 0.0)
            end
        end
    end
    turn!(w.rollers, dt)
    for m in w.motors
        m.peak = max(m.peak, min(m.need, m.force))
        m.travel += abs(m.drive) * dt
    end
    for r in w.rollers
        r.angle += omega(r) * dt
        r.force = zero(Vec2d)
        r.torque = 0.0
    end
    w.t += dt
    w.step += 1
    return
end

"Advances the world by one time step."
function step!(w::World)
    sheet_forces!(w)
    node_contacts!(w)
    segment_contacts!(w)
    sheet_contacts!(w)
    stack_load!(w)
    integrate!(w)
    return
end
