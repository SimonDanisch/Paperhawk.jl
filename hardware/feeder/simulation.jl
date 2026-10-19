# The feeder as a simulation: its profile as obstacles, its rollers, sheets in the tray,
# a gate at the exit nip that notes fed sheets, and the step-counting control the firmware would run.

"How the motors drive the rollers."
abstract type Drive end

"Pick, feed and exit roller each on their own motor, coupled directly."
struct ThreeMotors <: Drive end

"Pick and feed roller geared to one motor, the exit roller on a second."
struct TwoMotors <: Drive end

"""
All rollers geared to one motor. It runs forward to feed; then it reverses: pick and feed roller
stand behind their freewheels, and a rectifier (two freewheels driven in opposite senses) keeps
the exit roller turning forward. After reversing, the rectifier's second pawl has to reach the
next ratchet tooth: for up to `rectifier_lag` of travel the exit roller stands.
"""
struct OneMotor <: Drive end

"""
    FeedSettings(; kwargs...)

Everything about a feeder run that is not geometry: the paper, how many sheets lie in the tray
and how many of them are simulated (the top ones; the rest is a pile they lie on), friction
against paper, springs, motors and the step counts the firmware runs.

Small steppers drive the rollers (`drive`). Pick and feed roller sit behind freewheels
(`oneway`), so a stopped or slower motor never brakes the sheet the exit rollers pull. Per sheet
the firmware starts the motors and stops pick (`pick_travel`, only with its own motor) and feed
roller (`feed_travel`) once the exit rollers have the sheet, long before its tail reaches the
pick roller; the exit roller runs on to `eject_travel`, when the sheet lies in the box. The exit
motor turns its roller directly at `speed`; the other one drives pick and feed roller through
`reduction`, slower and stronger. Nothing senses the paper: the camera checks every result.

The pick roller hangs on an arm that swings about the feed roller's axis; the arm's weight
presses it on the stack (`pick_weight` at the roller, `pick_mass` moving along its swing). The
gears that drive it come in along the arm's axis, so their torque on the arm is the roller's
own: it adds nothing to the pressure.
"""
Base.@kwdef struct FeedSettings
    paper::Paper = Paper()
    shapes::Vector{Shape} = [Shape()]   # of the simulated sheets from the lowest up, repeating
    sheets::Int = 4                 # simulated sheets, the top of the stack
    stack::Int = 50                 # sheets in the tray, including the simulated ones
    cycles::Int = 2                 # sheets to feed before stopping
    pile::Float64 = 0.0             # m, height of the pile already in the box
    speed::Float64 = 0.01225        # m/s, commanded surface speed: a 28BYJ-48 at 9.75 rpm (333 full steps/s) on a 24 mm roller
    reduction::Float64 = 1.5        # feed roller's gear over the drive motor's pinion: 30 over 20 teeth
    drive::Drive = TwoMotors()
    motor::Float64 = 3.1            # N, most each motor gives at its roller surfaces: 37.3 mN·m measured at 333 full steps/s, over 12 mm
    rectifier_lag::Float64 = 0.0063 # m of travel the rectifier may need to take up after the motor reverses: one ratchet tooth
    pick_ratio::Float64 = 1.0       # pick roller's speed over the feed roller's, set by gears or its own motor
    gear_efficiency::Float64 = 0.9  # one printed spur gear mesh, dry PLA on PETG
    pick_travel::Float64 = 0.150    # m each motor runs per sheet: pick pushes until the exit nip has the sheet
    feed_travel::Float64 = 0.160    # until the exit rollers have the sheet; its tail is still far from the pick roller
    eject_travel::Float64 = 0.500   # runs on after the tail leaves, so the idler rolls it off
    oneway::Bool = true             # freewheels in pick and feed roller
    pick_weight::Float64 = 0.72     # N, the arm's weight on the stack, at the pick roller (`pick_force`)
    pick_mass::Float64 = 0.075      # kg, the arm with all it carries (86 g), as mass at the roller
    pad_force::Float64 = 0.9        # N, flexure pressing the pad onto the feed roller (PAD_FORCE)
    pad_rate::Float64 = 530.0       # N/m, 33 × 30 × 1.2 mm PETG leaf
    idler_force::Float64 = 3.0      # N, flexures pressing the lower exit roller up
    idler_rate::Float64 = 900.0     # N/m, two 40 × 20 × 2 mm PETG leaves
    bearing_drag::Float64 = 0.03    # N at the roller surface, printed plain bearings
    freewheel_drag::Float64 = 0.18  # N at the roller surface, the 0.9 mm pawl clicking over the ratchet (beam theory: 0.17)
    roller_inertia::Float64 = 0.005 # kg, I/r² of a roller with its hub
    paper_paper::Friction = Friction(0.45, 0.38)
    rubber::Friction = Friction(1.3, 1.1)       # roller tires: NBR O-rings
    pad::Friction = Friction(0.8, 0.7)          # separation pad: cork
    plastic::Friction = Friction(0.3, 0.25)     # printed guides and tray
    idler_grip::Friction = Friction(1.3, 1.1)   # lower exit rollers: O-rings too; bare PLA (0.3) left the tail of a sheet
                                                # lying on them with grippy paper over a pile in the box
    cardboard::Friction = Friction(0.45, 0.4)   # box walls
    contact::ContactModel = ContactModel()
    gravity::Vec2d = Vec2d(0, -9.81)
    air_density::Float64 = 1.2
    drag::Float64 = 1.5             # drag coefficient of a sheet moving face-on
    dt::Float64 = 5.0e-6
    settle::Float64 = 0.3           # s with motors off before the first pick
    rest::Float64 = 1.0             # s the motors stay off after each sheet (camera)
    stall_after::Float64 = 0.05     # s a motor may run short of force before it counts as stalled
end

"What happened to one sheet feed."
Base.@kwdef mutable struct Cycle
    start::Float64 = NaN
    fed::Vector{Int} = Int[]        # sheets whose head reached the exit nip in this cycle
    outcome::Symbol = :running
    stalled::Vector{Symbol} = Symbol[]
    height::Float64 = NaN           # mm, highest point of the fed sheet above the pile after resting
    relief::Float64 = NaN           # mm, how high the same sheet stands on a table by its own shape
    span::NTuple{2, Float64} = (NaN, NaN)   # mm, where the sheet lies along the box
    next_lead::Float64 = NaN        # mm, how far the next sheet's head got past the feed nip
    peak::Dict{Symbol, Float64} = Dict{Symbol, Float64}()   # N, largest force each motor gave, averaged over about 20 ms
end

"""
The firmware, counting steps only:

1. `:feed`: all motors run forward; pick and feed roller stop after their travel (`fed!`).
   The freewheels let a stopped pick or feed roller turn on with the sheet the others still pull.
2. `:eject`: once pick and feed stand, the exit roller runs until its motor has done
   `eject_travel` (`eject!`: a single motor runs backward for this).
3. `:rest`: all motors stop and the camera takes its picture.
"""
mutable struct Controller
    phase::Symbol
    since::Float64
    short::Dict{Symbol, Float64}    # s each motor has been running short of force
    smooth::Dict{Symbol, Float64}   # N, each motor's force averaged over about 20 ms
    cycles::Vector{Cycle}
end

"Everything static a sheet can touch, but the pile in the box."
struct Obstacles
    walls::Vector{Wall}
    concave::Vector{ConcaveArc}
    corners::Vector{Corner}
    convex::Vector{ConvexArc}
end

"""
The simulated feeder. Sheets are numbered by their place in the tray, the lowest first. A sheet
that has landed in the box leaves the world and becomes part of the pile there (`retire!`): the
next one lands on top of it, which the sheets' contacts, made for the order in the tray, could
not show.
"""
mutable struct FeederSim
    const design::FeederDesign
    const settings::FeedSettings
    world::World
    const pick::Motor
    const feed::Motor
    const exit::Motor
    const motors::Vector{Motor}         # the distinct ones
    const gate::Vec2d                   # exit nip, where a sheet counts as fed
    const gate_radius::Float64
    const fed_at::Vector{Float64}       # when each sheet's head first reached the exit nip
    const nip::Vec2d
    const down::Vec2d
    const box::NTuple{2, Float64}       # inner back and front wall, along y
    const controller::Controller
    const obstacles::Obstacles
    const ids::Vector{Int}              # the sheet each of the world's sheets is
    const landed::Dict{Int, Vector{Vec2d}}  # sheets out of the world, as they lay in the box
    pile::Float64                       # m, top of the pile in the box
end

meters(p) = Vec2d(p) * 1.0e-3

function add!(walls, corners, concave, convex, l::Line, fr)
    push!(walls, Wall(meters(l.a), meters(l.b), fr))
    return
end
function add!(walls, corners, concave, convex, a::Arc, fr)
    if a.inside
        push!(concave, ConcaveArc(meters(a.center), a.radius * 1.0e-3, a.start, a.stop, fr))
    else
        push!(convex, ConvexArc(meters(a.center), a.radius * 1.0e-3, a.start, a.stop, fr))
    end
    return
end
first_point(l::Line) = l.a
last_point(l::Line) = l.b
first_point(a::Arc) = a.center + a.radius * Vec2d(cos(a.start), sin(a.start))
last_point(a::Arc) = a.center + a.radius * Vec2d(cos(a.stop), sin(a.stop))

"""
    FeederSim(design, settings)

The feeder's profile as obstacles, its rollers and pad, and the top `settings.sheets` sheets of
a stack of `settings.stack` lying face up in the tray, leading edges against the ramp; the rest
of the stack is a pile of paper they lie on. The top sheet is fed first.
"""
function FeederSim(d::FeederDesign, s::FeedSettings)
    p = Profile(d)
    mm = 1.0e-3
    t = s.paper.thickness
    walls, corners, concave, convex = Wall[], Corner[], ConcaveArc[], ConvexArc[]
    add!(walls, corners, concave, convex, p.tray, s.plastic)
    add!(walls, corners, concave, convex, p.fillet, s.plastic)
    add!(walls, corners, concave, convex, p.ramp, s.plastic)
    push!(corners, Corner(meters(p.tray.a), s.plastic), Corner(meters(p.ramp.b), s.plastic))
    # The part of the stack below the simulated sheets, as a pile of paper they lie on.
    base = max(s.stack - s.sheets, 0) * t / mm
    # Its top reaches 2 mm into the ramp, so a sheet's crease cannot slip under the pile's front edge.
    base > 0 && push!(walls, Wall(meters(along(p, -d.tray_length, base)), meters(along(p, ramp_at(p, base) + 2.0, base)), s.paper_paper; floor = true))
    for guide in (p.lower_guide, p.upper_guide)
        foreach(piece -> add!(walls, corners, concave, convex, piece, s.plastic), guide)
        push!(corners, Corner(meters(first_point(first(guide))), s.plastic))
        push!(corners, Corner(meters(last_point(last(guide))), s.plastic))
    end
    back, _, front = p.box
    add!(walls, corners, concave, convex, back, s.cardboard)
    add!(walls, corners, concave, convex, front, s.cardboard)
    push!(corners, Corner(meters(back.a), s.cardboard), Corner(meters(front.b), s.cardboard))
    obstacles = Obstacles(walls, concave, corners, convex)

    pick, feed, exit = drive_motors(s.drive, s)
    roller(name, at, radius, fr; kw...) = Roller(name, meters(at), radius * mm, fr; inertia = s.roller_inertia,
        drag = s.bearing_drag, clutch = s.freewheel_drag, kw...)
    rollers = [
        pick_roller(p, d, s, base, pick),
        roller(:feed, p.feed, d.feed_radius, s.rubber; spin = 1.0, motor = feed, oneway = s.oneway, efficiency = mesh_efficiency(s.drive, s)),
        Roller(:pad, meters(p.pad), d.pad_radius * mm, s.pad; axis = -left(p.entry), mass = 0.005, preload = s.pad_force, rate = s.pad_rate),
        # The upper exit roller is driven; the lower one is a plain idler that springs press up.
        roller(:exit_low, p.exit_low, d.exit_radius, s.idler_grip; spin = -1.0, axis = Vec2d(0, -1),
            preload = s.idler_force, rate = s.idler_rate),
        roller(:exit_up, p.exit_up, d.exit_radius, s.rubber; spin = 1.0, motor = exit, exit_coupling(s.drive)...),
    ]

    n = node_count(s.paper)
    ds = spacing(s.paper)
    sheets = map(1:s.sheets) do k
        h = base * mm + (k - 0.5) * t + 2.0e-5
        lead = ramp_at(p, h / mm) * mm - 3.0e-4          # leading edge against the ramp
        [meters(p.foot) + (lead - (j - 1) * ds) * p.down + h * p.normal for j in 1:n]
    end
    ids = collect(1:s.sheets)
    world = feeder_world(d, s, obstacles, rollers, sheets, ids, s.pile)
    controller = Controller(:settle, 0.0, Dict(m.name => 0.0 for m in (pick, feed, exit)),
        Dict(m.name => 0.0 for m in (pick, feed, exit)), Cycle[])
    return FeederSim(d, s, world, pick, feed, exit, unique([pick, feed, exit]), meters(p.exit), (d.guide_gap / 2 + 0.5) * mm, fill(NaN, s.sheets),
        meters(p.nip), p.entry, (0.0, d.box_length * mm), controller, obstacles, ids, Dict{Int, Vector{Vec2d}}(), s.pile)
end

"The world of sheets `ids` at the node positions `sheets` among the obstacles, over a pile `pile` m high in the box."
function feeder_world(d::FeederDesign, s::FeedSettings, o::Obstacles, rollers, sheets, ids, pile)
    top = Wall(Vec2d(0, pile), Vec2d(d.box_length * 1.0e-3, pile), s.paper_paper; floor = true)
    shapes = [s.shapes[mod1(k, length(s.shapes))] for k in ids]
    return World(sheets, vcat(o.walls, top), o.concave, o.corners, o.convex, rollers; paper = s.paper, shapes, s.contact,
        s.paper_paper, s.gravity, s.air_density, s.drag, s.dt, load = no_load())
end

"Where sheet `k` is in the world, or `nothing` once it has left it."
slot(sim::FeederSim, k) = findfirst(==(k), sim.ids)

"Sheet `k`'s nodes: in the world, or as it lay when it left it."
sheet_points(sim::FeederSim, k) = (j = slot(sim, k); j === nothing ? sim.landed[k] : sheet_points(sim.world, j))

"""
    retire!(sim, k)

Takes sheet `k`, which lies in the box, out of the world: the pile there grows by a sheet and
the other sheets go on as they were.
"""
function retire!(sim::FeederSim, k)
    w = sim.world
    j = slot(sim, k)
    sim.landed[k] = sheet_points(w, j)
    keep = [i for i in 1:w.sheets if i != j]
    sim.pile += sim.settings.paper.thickness
    world = feeder_world(sim.design, sim.settings, sim.obstacles, w.rollers, [sheet_points(w, i) for i in keep], sim.ids[keep], sim.pile)
    world.v .= reduce(vcat, [w.v[sheet_nodes(w, i)] for i in keep])
    world.t, world.step = w.t, w.step
    deleteat!(sim.ids, j)
    sim.world = world
    return
end

"""
    pick_roller(p, d, s, base, motor)

The pick roller on its arm: it rises along its swing about the feed roller's axis and the arm's
weight presses it down with `pick_weight`. At `lift = 0` it rests on the pile `base` mm high
under the simulated sheets.
"""
function pick_roller(p::Profile, d::FeederDesign, s::FeedSettings, base, motor::Motor)
    mm = 1.0e-3
    home = pick_center(p, d, base)
    axis = pick_lift(p, d, base)
    wheel = Roller(:pick, meters(home), d.pick_radius * mm, s.rubber; axis, mass = s.pick_mass, preload = s.pick_weight * dot(axis, p.normal),
        spin = 1.0, inertia = s.roller_inertia, drag = s.bearing_drag, clutch = s.freewheel_drag, motor, oneway = s.oneway,
        ratio = s.pick_ratio, efficiency = pick_efficiency(s.drive, s))
    wheel.lift = (s.sheets * s.paper.thickness + 2.0e-5) / dot(axis, p.normal)
    return wheel
end

"The motors that turn pick, feed and exit roller."
drive_motors(::ThreeMotors, s::FeedSettings) = Tuple(Motor(n, s.motor; s.speed) for n in (:pick, :feed, :exit))
function drive_motors(::TwoMotors, s::FeedSettings)
    m = Motor(:pick_feed, s.motor * s.reduction; speed = s.speed / s.reduction)
    return (m, m, Motor(:exit, s.motor; s.speed))
end
function drive_motors(::OneMotor, s::FeedSettings)
    m = Motor(:motor, s.motor; s.speed)
    return (m, m, m)
end

"""
Share of the motor's work that reaches the feed roller, and the pick roller: all of it straight
on a motor; through gears, one mesh to the feed roller (pinion, feed gear) and three to the pick
roller (on through the arm's idler to the pick gear).
"""
mesh_efficiency(::ThreeMotors, s::FeedSettings) = 1.0
mesh_efficiency(::Drive, s::FeedSettings) = s.gear_efficiency
pick_efficiency(::ThreeMotors, s::FeedSettings) = 1.0
pick_efficiency(::Drive, s::FeedSettings) = s.gear_efficiency^3

"How the exit roller hangs on its motor: directly, or behind the rectifier."
exit_coupling(::Drive) = (oneway = false,)
exit_coupling(::OneMotor) = (oneway = true, rectified = true)

elapsed(sim::FeederSim) = sim.world.t
rollers(sim::FeederSim) = sim.world.rollers

"Distance from `p` to segment `a`-`b`."
distance(p::Vec2d, a::Vec2d, b::Vec2d) = norm(p - first(closest(a, b, p)))

motors(sim::FeederSim) = sim.motors

"Notes when each sheet's head first reaches the exit nip."
function gate!(sim::FeederSim)
    w = sim.world
    for (j, k) in enumerate(sim.ids)
        isnan(sim.fed_at[k]) || continue
        r = sheet_nodes(w, j)
        for i in first(r):(last(r) - 1)
            if distance(sim.gate, w.x[i], w.x[i + 1]) < sim.gate_radius
                sim.fed_at[k] = w.t
                break
            end
        end
    end
    return
end

function start_cycle!(sim::FeederSim)
    c = sim.controller
    push!(c.cycles, Cycle(start = elapsed(sim)))
    c.phase, c.since = :feed, elapsed(sim)
    for m in motors(sim)
        m.travel, m.peak = 0.0, 0.0
        m.drive = m.speed
    end
    return
end

"""
How the sheet lies on the pile: inside the box, not folded over, and no more than 5 mm higher
than its own shape makes it stand on a table (`relief`), so the camera sees all of it.
"""
function landing!(cycle::Cycle, sim::FeederSim, k)
    s = sim.settings
    pts = sheet_points(sim, k)
    ys = first.(pts)
    zs = last.(pts)
    cycle.span = (minimum(ys) * 1.0e3, maximum(ys) * 1.0e3)
    cycle.height = (maximum(zs) - sim.pile) * 1.0e3
    cycle.relief = relief(s.paper, s.shapes[mod1(k, length(s.shapes))])
    inside = sim.box[1] <= minimum(ys) && maximum(ys) <= sim.box[2]
    folded = any(>(1.0e-3), diff(ys))          # nodes run from the head at the front to the tail
    cycle.outcome = inside && !folded && cycle.height < cycle.relief + 5.0 ? :landed : :misplaced
    return
end

"""
    relief(paper, shape; time = 1.0)

How high a sheet stands on a table by its own shape, in mm: laid down flat and face up, then
left to settle for `time`.
"""
function relief(paper::Paper, shape::Shape; time = 1.0, friction = Friction(0.45, 0.38))
    n = node_count(paper)
    ds = spacing(paper)
    sheet = [Vec2d((n - j) * ds, paper.thickness / 2 + 2.0e-5) for j in 1:n]
    table = Wall(Vec2d(-0.1, 0), Vec2d(paper.length + 0.1, 0), friction)
    w = World([sheet], [table], ConcaveArc[], Corner[], ConvexArc[], Roller[]; paper, shapes = [shape])
    for _ in 1:round(Int, time / w.dt)
        step!(w)
    end
    return maximum(last, w.x) * 1.0e3
end

"How far past the feed nip the head of the first sheet not yet fed got, in mm."
function next_lead(sim::FeederSim)
    k = findlast(isnan, sim.fed_at)
    k === nothing && return NaN
    return dot(sheet_points(sim, k)[1] - sim.nip, sim.down) * 1.0e3
end

function finish!(sim::FeederSim)
    c = sim.controller
    cycle = last(c.cycles)
    cycle.fed = findall(t -> !isnan(t) && t >= cycle.start, sim.fed_at)
    cycle.next_lead = next_lead(sim)
    cycle.outcome = isempty(cycle.fed) ? :misfeed : length(cycle.fed) > 1 ? :double : :fed
    length(cycle.fed) == 1 && landing!(cycle, sim, only(cycle.fed))
    isempty(cycle.stalled) || cycle.outcome == :landed || (cycle.outcome = :stall)
    cycle.outcome == :landed && length(sim.ids) > 1 && retire!(sim, only(cycle.fed))
    if cycle.outcome == :landed && length(c.cycles) < sim.settings.cycles
        start_cycle!(sim)
    else
        c.phase = :done
    end
    return
end

"""
Counts how long each running motor has been short of force; past `stall_after` it stalled.
Also keeps each motor's force averaged over about 20 ms, so the peak is what the motor has to
hold, not the single-step kick when it starts.
"""
function watch!(sim::FeederSim, dt; τ = 0.02)
    c = sim.controller
    cycle = last(c.cycles)
    for m in motors(sim)
        short = m.drive != 0 && m.need > m.force
        c.short[m.name] = short ? c.short[m.name] + dt : 0.0
        c.short[m.name] > sim.settings.stall_after && !(m.name in cycle.stalled) && push!(cycle.stalled, m.name)
        given = m.drive != 0 ? min(m.need, m.force) : 0.0
        c.smooth[m.name] += (given - c.smooth[m.name]) * dt / τ
        cycle.peak[m.name] = max(get(cycle.peak, m.name, 0.0), c.smooth[m.name])
    end
    return
end

function control!(sim::FeederSim, dt)
    c = sim.controller
    s = sim.settings
    t = elapsed(sim)
    gate!(sim)
    c.phase == :settle || c.phase == :done || watch!(sim, dt)
    if c.phase == :settle
        t >= s.settle && start_cycle!(sim)
    elseif c.phase == :feed
        fed!(s.drive, sim) && ((c.phase, c.since) = (:eject, t))
    elseif c.phase == :eject
        eject!(s.drive, sim, t - c.since)
        if sim.exit.travel >= s.eject_travel
            sim.exit.drive = 0.0
            c.phase, c.since = :rest, t
        end
    elseif c.phase == :rest
        t - c.since > s.rest && finish!(sim)
    end
    return
end

"""
    fed!(drive, sim)

Stops pick and feed roller after their travel; true once both stand and only the exit roller
runs on.
"""
function fed!(::ThreeMotors, sim::FeederSim)
    s = sim.settings
    sim.pick.travel >= s.pick_travel && (sim.pick.drive = 0.0)
    sim.feed.travel >= s.feed_travel && (sim.feed.drive = 0.0)
    return sim.pick.drive == 0 && sim.feed.drive == 0
end

function fed!(::TwoMotors, sim::FeederSim)
    sim.feed.travel >= sim.settings.feed_travel && (sim.feed.drive = 0.0)
    return sim.feed.drive == 0
end

"The one motor stops after `feed_travel`; `eject!` runs it backward."
function fed!(::OneMotor, sim::FeederSim)
    m = sim.exit
    m.travel >= sim.settings.feed_travel && (m.drive = 0.0)
    return m.drive == 0
end

eject!(::Drive, sim::FeederSim, since) = nothing

"""
Backward, the motor turns pick and feed roller's freewheel cups the wrong way, so both stand;
the rectifier's second freewheel takes the exit roller along once its pawl has reached the next
tooth. Until then the exit roller stands: modeled as the motor standing for `rectifier_lag`
(worst case, one whole tooth), which the firmware adds to its steps.
"""
function eject!(::OneMotor, sim::FeederSim, since)
    s = sim.settings
    m = sim.exit
    m.drive == 0 && since >= s.rectifier_lag / s.speed && m.travel < s.eject_travel && (m.drive = -s.speed)
    return
end

"""
With no paper between them, the springs press the idler onto the driven exit roller, which
turns it by friction: rolling on each other, both surfaces move at the same speed.
"""
function couple_exit!(sim::FeederSim; gap = 0.03e-3)
    rs = sim.world.rollers
    idle = rs[findfirst(r -> r.name == :exit_low, rs)]
    driven = rs[findfirst(r -> r.name == :exit_up, rs)]
    idle.lift < gap && (idle.speed = driven.speed)
    return
end

function step!(sim::FeederSim)
    step!(sim.world)
    couple_exit!(sim)
    sim.world.step % 10 == 0 && control!(sim, 10 * sim.settings.dt)
    return
end

"One recorded moment of a run, for plots and animations (meters and radians)."
struct Frame
    t::Float64
    sheets::Vector{Vector{Vec2d}}
    lifts::Vector{Float64}
    angles::Vector{Float64}
    tension::Float64            # N, highest segment tension
    phase::Symbol
end

function Frame(sim::FeederSim)
    w = sim.world
    return Frame(w.t, [sheet_points(sim, k) for k in eachindex(sim.fed_at)], [r.lift for r in w.rollers],
        [r.angle for r in w.rollers], maximum(w.tension), sim.controller.phase)
end

"""
    run!(sim; fps = 60, max_time = 20.0)

Runs until the controller is done or `max_time` (simulated seconds) has passed and returns the
frames recorded at `fps`.
"""
function run!(sim::FeederSim; fps = 60, max_time = 20.0)
    every = round(Int, 1 / (fps * sim.settings.dt))
    frames = [Frame(sim)]
    while sim.controller.phase != :done && elapsed(sim) < max_time
        step!(sim)
        sim.world.step % every == 0 && push!(frames, Frame(sim))
    end
    push!(frames, Frame(sim))
    return frames
end
