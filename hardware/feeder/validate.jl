# Cross-check of the physics against MuJoCo on a small case both can run quickly: two short
# sheets hanging into the nip between a driven roller and a spring-loaded pad. Sheet 1 touches
# the roller, sheet 2 the pad. With a pad that grips harder than paper on paper, only sheet 1
# should go through; with a slippery pad, both.

"""
    NipTest(; kwargs...)

The shared setup: sheets of `length` (m) with their leading edges `lead` before the nip,
roller and pad of `radius`, the pad pressed with `force`, friction coefficients against paper.
MuJoCo has a single friction coefficient per contact, so static and sliding friction are equal.
"""
Base.@kwdef struct NipTest
    length::Float64 = 0.10
    lead::Float64 = 0.003
    radius::Float64 = 0.012
    force::Float64 = 1.5
    speed::Float64 = 0.15
    paper_paper::Float64 = 0.45
    rubber::Float64 = 1.2
    pad::Float64 = 0.6
    duration::Float64 = 0.3
end

"Leading edge travel of both sheets and the pad's largest lift, all in millimeters."
struct NipResult
    sheet1::Float64
    sheet2::Float64
    lift::Float64
    seconds::Float64            # computing time
end

"""
    run_nip(PaperFeeder.World, test)

The nip test with this package's physics.
"""
function run_nip(::Type{World}, n::NipTest; dt = 5.0e-6)
    paper = Paper(length = n.length)
    t = paper.thickness
    ds = spacing(paper)
    N = node_count(paper)
    sheets = [[Vec2d(-n.lead - (j - 1) * ds, (k - 0.5) * t) for j in 1:N] for k in 1:2]
    motor = Motor(:roller, 100.0)
    rollers = [
        Roller(:roller, Vec2d(0, -n.radius), n.radius, Friction(n.rubber); spin = -1.0, motor),
        Roller(:pad, Vec2d(0, n.radius), n.radius, Friction(n.pad); axis = Vec2d(0, 1), mass = 0.005, preload = n.force),
    ]
    rollers[2].lift = 2t            # the pad's stop is on the bare roller; the two sheets lift it
    w = World(sheets, Wall[], ConcaveArc[], Corner[], ConvexArc[], rollers; paper, paper_paper = Friction(n.paper_paper), dt)
    motor.drive = n.speed
    start = (w.x[1][1], w.x[N + 1][1])
    lift = 0.0
    seconds = @elapsed for _ in 1:round(Int, n.duration / dt)
        step!(w)
        lift = max(lift, rollers[2].lift)
    end
    return NipResult((w.x[1][1] - start[1]) * 1.0e3, (w.x[N + 1][1] - start[2]) * 1.0e3, lift * 1.0e3, seconds)
end

"The nip test as MuJoCo model text: sheets are hinged chains of thin capsules."
function nip_mjcf(n::NipTest; dt = 2.0e-5, ds = 0.004, t = 1.0e-4, B = 7.0e-5, width = 0.21, grammage = 0.08)
    links = round(Int, n.length / ds)
    m = grammage * width * ds
    I = m * ds^2 / 12
    kb = B / ds
    R = n.radius
    io = IOBuffer()
    print(io, """
    <mujoco>
      <option timestep="$dt" integrator="implicitfast" cone="elliptic" impratio="10"/>
      <default><geom solref="$(2dt) 1" solimp="0.95 0.99 0.0001" condim="3"/></default>
      <worldbody>
        <body name="roller" pos="0 0 $(-R)">
          <joint name="roll" type="hinge" axis="1 0 0"/>
          <geom type="capsule" fromto="-0.015 0 0 0.015 0 0" size="$R" friction="$(n.rubber)" priority="1" mass="5"/>
        </body>
        <body name="pad" pos="0 0 $R">
          <joint name="lift" type="slide" axis="0 0 1" range="0 0.01" limited="true" solreflimit="$(2dt) 1"/>
          <geom type="capsule" fromto="-0.015 0 0 0.015 0 0" size="$R" friction="$(n.pad)" priority="1" mass="0.005"/>
        </body>
    """)
    for k in 1:2
        bit = 1 << k
        geom = """<geom type="capsule" fromto="0 0 0 0 $(-ds) 0" size="$(t / 2)" friction="$(n.paper_paper)" contype="$bit" conaffinity="$(0xff ⊻ bit)"/>"""
        inertial = """<inertial pos="0 $(-ds / 2) 0" mass="$m" diaginertia="$I $I $I"/>"""
        print(io, """<body pos="$(-n.lead) 0 $((k - 0.5) * t)">
          <joint type="slide" axis="0 1 0"/><joint type="slide" axis="0 0 1"/><joint type="hinge" axis="1 0 0"/>
          $inertial $geom""")
        for _ in 2:links
            print(io, """<body pos="0 $(-ds) 0"><joint type="hinge" axis="1 0 0" stiffness="$kb" damping="$(0.05 * sqrt(kb * I))"/>
              $inertial $geom""")
        end
        print(io, "</body>"^links)
    end
    print(io, "</worldbody></mujoco>")
    return String(take!(io))
end

"""
    run_nip(MuJoCo, test)

The nip test in MuJoCo, at the 20 µs step its soft contacts need to keep the pad within a
fraction of the paper's thickness.
"""
function run_nip(::Type{MuJoCo.Model}, n::NipTest; dt = 2.0e-5, ds = 0.004)
    path = tempname() * ".xml"
    write(path, nip_mjcf(n; dt, ds))
    model = MuJoCo.load_model(path)
    data = MuJoCo.init_data(model)
    rm(path)
    data.qpos[2] = 2.0e-4           # the pad's stop is on the bare roller; the two sheets lift it
    MuJoCo.mj_forward(model, data)
    links = round(Int, n.length / ds)
    y1, y2 = 3, 3 + links + 2       # root slide of each sheet; dofs 1 and 2 are roller and pad
    start = (data.qpos[y1], data.qpos[y2])
    lift = 0.0
    seconds = @elapsed for _ in 1:round(Int, n.duration / dt)
        data.qvel[1] = -n.speed / n.radius
        data.qfrc_applied[2] = -(n.force - 0.005 * 9.81)
        MuJoCo.step!(model, data)
        lift = max(lift, data.qpos[2])
    end
    return NipResult((data.qpos[y1] - start[1]) * 1.0e3, (data.qpos[y2] - start[2]) * 1.0e3, lift * 1.0e3, seconds)
end

"""
    compare_nip(; pads = (0.3, 0.5, 0.6, 0.9))

Runs the nip test in both simulations for each pad friction coefficient.
"""
function compare_nip(; pads = (0.3, 0.5, 0.6, 0.9), kwargs...)
    return map(pads) do μ
        test = NipTest(; pad = μ, kwargs...)
        (pad = μ, ours = run_nip(World, test), mujoco = run_nip(MuJoCo.Model, test))
    end
end
