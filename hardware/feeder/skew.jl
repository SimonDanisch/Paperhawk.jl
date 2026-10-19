# Skew: how the sheet turns and drifts sideways in its own plane on its way through, in MuJoCo.
# The side-view simulation already resolves how the sheet bends along the paper path; across
# the sheet it cannot see anything. Here the path is unrolled into a plane and the sheet is a
# rigid plate in it (paper barely stretches in its plane), free to move along and across the
# path and to turn. Every roller is a rigid body of a few short cylinders across its width, so
# MuJoCo's friction contacts set where along the roller the sheet is gripped: a roller pair
# that runs faster on one side, a spring that presses harder, a fence the sheet rubs on all turn
# it. Units are SI.

"""
    SkewSettings(; kwargs...)

The asymmetries to try and the forces from the side-view design: the left exit roller bigger
by `exit_radius_difference` (O-ring cord and printed hub tolerances), the lower exit rollers'
springs pressing with `idler_forces` (left, right), the sheet starting `offset` toward +x in its
stack, and friction coefficients against paper. The pick roller's weight presses the sheet onto
the stack under it, the pad presses it up against the feed roller.
"""
Base.@kwdef struct SkewSettings
    exit_radius_difference::Float64 = 0.0
    idler_forces::NTuple{2, Float64} = (1.5, 1.5)
    offset::Float64 = 0.0
    pick::Float64 = 0.72            # N, the pick arm's weight (`pick_force`)
    pad::Float64 = 0.9              # N, the printed pad spring (PAD_FORCE)
    paper_paper::Float64 = 0.45
    rubber::Float64 = 1.3
    cork::Float64 = 0.8
    plastic::Float64 = 0.3
    speed::Float64 = 0.01225        # m/s at the exit roller; pick and feed roller 1.5 times slower
    reduction::Float64 = 1.5
    feed_travel::Float64 = 0.160
    eject_travel::Float64 = 0.500
    motor::Float64 = 3.1            # N at a roller surface straight on the motor (37.3 mN·m measured at 9.75 rpm)
    dt::Float64 = 1.0e-4
end

"Cylinders across x, `n` side by side over `width`, centered at `x`, as MuJoCo geoms."
function roller_geoms(x, width, r, n, friction; name)
    w = width / n
    join(["""<geom name="$(name)_$k" type="cylinder" size="$r $(w / 2 - 1.0e-4)" pos="$(x - width / 2 + (k - 0.5) * w) 0 0" euler="0 90 0" friction="$friction 0.005 0.0001" priority="1"/>"""
          for k in 1:n], "\n")
end

"""
Where pick roller and stack are along the unrolled path, in mm from the feed nip (negative:
before it): the pick roller's contact with a half full stack, and the ramp's foot, where the
stack's leading edges stand.
"""
function skew_stations(d::FeederDesign)
    p = Profile(d)
    contact = pick_center(p, d, d.stack_height / 2) - d.pick_radius * p.normal
    foot = norm(Vec2d(p.nip - p.foot))
    return (pick = -(foot + dot(Vec2d(p.foot - contact), p.down)), foot = -foot)
end

"""
    skew_xml(design, build, settings)

The unrolled feeder for MuJoCo: y runs along the paper path from the feed nip toward the box,
x across the sheet, the sheet in the plane z = 0. Rollers below the sheet push up, pads and
rollers above it push down, each on a slide joint with the force from the design (applied in
`SkewSim`).
"""
function skew_xml(d::FeederDesign, b::Build, s::SkewSettings)
    mm = 1.0e-3
    L, W = d.sheet_length * mm, d.sheet_width * mm
    r = d.feed_radius * mm
    t = 1.0e-3                      # half thickness of the sheet's collision plate: thin boxes give MuJoCo poor contact normals
    exit_y = path_length(d) * mm
    st = skew_stations(d)
    pick_y, foot_y = st.pick * mm, st.foot * mm
    half = d.inner_width / 2 * mm
    fence = (d.sheet_width / 2 + 1.5) * mm
    fence_end = pick_y - (d.pick_radius + 6.0) * mm      # the fences end before the pick shaft
    fence_start = foot_y - d.tray_length * mm
    xr = b.exit_rollers[2] * mm
    er = b.exit_roller_length * mm
    δ = s.exit_radius_difference
    # Pressing bodies move 2 mm away from the sheet but only 0.2 mm past its face, so a sheet's
    # leading edge runs into the next nip instead of against a roller that dropped.
    # Heavily damped, so a pressing body settles on the sheet instead of bouncing off it.
    up = """<joint type="slide" axis="0 0 1" range="-0.002 0.0002" limited="true" damping="50" armature="0.05"/>"""
    down = """<joint type="slide" axis="0 0 1" range="-0.0002 0.002" limited="true" damping="50" armature="0.05"/>"""
    spin(name) = """<joint name="$name" type="hinge" axis="1 0 0" damping="1e-5"/>"""
    return """
    <mujoco model="feeder skew">
      <option timestep="$(s.dt)" gravity="0 0 0" cone="elliptic" impratio="10" integrator="implicitfast"/>
      <default><geom contype="2" conaffinity="1" condim="3" solref="0.002 1" solimp="0.95 0.99 0.0001"/></default>
      <worldbody>
        <body name="sheet" pos="$(s.offset) $(-L / 2 + 3.0e-3) 0">
          <joint name="sheet_x" type="slide" axis="1 0 0"/>
          <joint name="sheet_y" type="slide" axis="0 1 0"/>
          <joint name="sheet_turn" type="hinge" axis="0 0 1"/>
          <geom type="box" size="$(W / 2) $(L / 2) $t" mass="$(d.sheet_width * d.sheet_length * 1.0e-6 * 0.08)" contype="1" conaffinity="2" friction="0.01 0.005 0.0001" priority="0"/>
        </body>
        <body name="pick" pos="0 $pick_y $(r + t)">$down $(spin("pick_spin"))
          $(roller_geoms(0.0, b.roller_length * mm, r, 3, s.rubber; name = "pick"))
        </body>
        <body name="feed" pos="0 0 $(r + t)">$down $(spin("feed_spin"))
          $(roller_geoms(0.0, b.roller_length * mm, r, 3, s.rubber; name = "feed"))
        </body>
        <body name="pad" pos="0 0 $(-r - t)">$up
          $(roller_geoms(0.0, d.pad_width * mm, r, 3, s.cork; name = "pad"))
        </body>
        <body name="stack" pos="0 $((foot_y + fence_start) / 2) $(-0.005 - t)">$up
          <geom type="box" size="$(W / 2) $((foot_y - fence_start) / 2) 0.005" friction="$(s.paper_paper) 0.005 0.0001" priority="1"/>
        </body>
        <body name="exit_up_l" pos="$(-xr) $exit_y $(r + δ + t)">$down $(spin("exit_l_spin"))
          $(roller_geoms(0.0, er, r + δ, 2, s.rubber; name = "exit_up_l"))
        </body>
        <body name="exit_up_r" pos="$xr $exit_y $(r + t)">$down $(spin("exit_r_spin"))
          $(roller_geoms(0.0, er, r, 2, s.rubber; name = "exit_up_r"))
        </body>
        <body name="idler_l" pos="$(-xr) $exit_y $(-r - t)">$up $(spin("idler_l_spin"))
          $(roller_geoms(0.0, er, r, 2, s.rubber; name = "idler_l"))
        </body>
        <body name="idler_r" pos="$xr $exit_y $(-r - t)">$up $(spin("idler_r_spin"))
          $(roller_geoms(0.0, er, r, 2, s.rubber; name = "idler_r"))
        </body>
        <geom name="plate_l" type="box" size="0.004 0.4 0.01" pos="$(-half - 0.004) 0 0" friction="$(s.plastic) 0.005 0.0001" priority="1"/>
        <geom name="plate_r" type="box" size="0.004 0.4 0.01" pos="$(half + 0.004) 0 0" friction="$(s.plastic) 0.005 0.0001" priority="1"/>
        <geom name="fence_l" type="box" size="0.001 $((fence_end - fence_start) / 2) 0.01" pos="$(-fence - 0.001) $((fence_end + fence_start) / 2) 0" friction="$(s.plastic) 0.005 0.0001" priority="1"/>
        <geom name="fence_r" type="box" size="0.001 $((fence_end - fence_start) / 2) 0.01" pos="$(fence + 0.001) $((fence_end + fence_start) / 2) 0" friction="$(s.plastic) 0.005 0.0001" priority="1"/>
      </worldbody>
      <actuator>
        <velocity name="pick" joint="pick_spin" kv="1.0" forcerange="0 $(s.motor * s.reduction * r)"/>
        <velocity name="feed" joint="feed_spin" kv="1.0" forcerange="0 $(s.motor * s.reduction * r)"/>
        <velocity name="exit_l" joint="exit_l_spin" kv="1.0" forcerange="0 $(s.motor * r / 2)"/>
        <velocity name="exit_r" joint="exit_r_spin" kv="1.0" forcerange="0 $(s.motor * r / 2)"/>
      </actuator>
    </mujoco>"""
end

"""
The skew model running: MuJoCo model and data, the bodies that press (index, force along z)
and the firmware's step count, as surface travel of each motor.
"""
mutable struct SkewSim
    settings::SkewSettings
    model::MuJoCo.Model
    data::MuJoCo.Data
    travel::Vector{Float64}             # m, drive and exit motor
    exit_y::Float64                     # m, exit nip along the path
    length::Float64                     # m, sheet length
end

body_id(m::MuJoCo.Model, name) = MuJoCo.LibMuJoCo.mj_name2id(m, MuJoCo.LibMuJoCo.mjOBJ_BODY, name)
joint_qpos(m::MuJoCo.Model, name) = m.jnt_qposadr[MuJoCo.LibMuJoCo.mj_name2id(m, MuJoCo.LibMuJoCo.mjOBJ_JOINT, name) + 1] + 1

function SkewSim(d::FeederDesign, b::Build, s::SkewSettings)
    path = tempname() * ".xml"
    write(path, skew_xml(d, b, s))
    model = MuJoCo.load_model(path)
    rm(path)
    data = MuJoCo.init_data(model)
    # Pressing forces on each body's slide joint (its first degree of freedom): the stack and the
    # pad push up, pick and feed roller push down. The exit rollers stand open until the sheet's
    # leading edge is through (`run!`).
    for (name, f) in (("pick", -s.pick), ("stack", s.pick), ("feed", -s.pad), ("pad", s.pad))
        data.qfrc_applied[lift_dof(model, name)] = f
    end
    open_exit!(model, data, s)
    return SkewSim(s, model, data, [0.0, 0.0], path_length(d) * 1.0e-3, d.sheet_length * 1.0e-3)
end

lift_dof(m::MuJoCo.Model, name) = m.body_dofadr[body_id(m, name) + 1] + 1

"""
A sheet only 0.1 mm thick slips into the exit nip by itself; the model's 2 mm plate cannot. So
the exit rollers stand pulled apart until the leading edge has passed, then the springs close them.
"""
function open_exit!(m::MuJoCo.Model, dd::MuJoCo.Data, s::SkewSettings)
    for (name, f) in (("exit_up_l", 0.5), ("idler_l", -0.5), ("exit_up_r", 0.5), ("idler_r", -0.5))
        dd.qfrc_applied[lift_dof(m, name)] = f
    end
end

function close_exit!(m::MuJoCo.Model, dd::MuJoCo.Data, s::SkewSettings)
    for (name, f) in (("exit_up_l", -s.idler_forces[1]), ("idler_l", s.idler_forces[1]),
                      ("exit_up_r", -s.idler_forces[2]), ("idler_r", s.idler_forces[2]))
        dd.qfrc_applied[lift_dof(m, name)] = f
    end
end

"Sheet position across the path (m), along it (m) and its turn (degrees)."
function sheet_pose(sim::SkewSim)
    m, q = sim.model, sim.data.qpos
    return (x = q[joint_qpos(m, "sheet_x")], y = q[joint_qpos(m, "sheet_y")], turn = rad2deg(q[joint_qpos(m, "sheet_turn")]))
end

"""
    run!(sim::SkewSim; record = 0.05)

Runs the firmware's sheet: pick and feed roller (one motor, `reduction` slower) and exit
rollers start together, the drive stops after `feed_travel`, the exit after `eject_travel` or
once the sheet's tail has left the exit nip, where the sheet drops into the box. Returns the
sheet's pose every `record` seconds.
"""
function run!(sim::SkewSim; record = 0.05)
    s, m, dd = sim.settings, sim.model, sim.data
    radius = 0.012
    poses = [sheet_pose(sim)]
    every = round(Int, record / s.dt)
    k = 0
    closed = false
    head(p) = p.y + 3.0e-3                       # the leading edge starts 3 mm into the feed nip
    while sim.travel[2] < s.eject_travel && head(sheet_pose(sim)) - sim.length < sim.exit_y
        if !closed && head(sheet_pose(sim)) > sim.exit_y + 3.0e-3
            close_exit!(m, dd, s)
            closed = true
        end
        drive = sim.travel[1] < s.feed_travel
        ω = s.speed / radius
        dd.ctrl[1] = drive ? ω / s.reduction : 0.0    # pick and feed roller, above the sheet like the exit rollers
        dd.ctrl[2] = drive ? ω / s.reduction : 0.0
        dd.ctrl[3] = ω
        dd.ctrl[4] = ω
        MuJoCo.step!(m, dd)
        drive && (sim.travel[1] += s.speed / s.reduction * s.dt)
        sim.travel[2] += s.speed * s.dt
        (k += 1) % every == 0 && push!(poses, sheet_pose(sim))
    end
    push!(poses, sheet_pose(sim))
    return poses
end

"""
    skew_cases()

The asymmetries a print and its bought parts bring, alone and together, as name => settings.
"""
skew_cases() = [
    "left exit roller 0.1 mm bigger" => SkewSettings(exit_radius_difference = 1.0e-4),
    "left exit roller 0.2 mm bigger, worn O-rings" => SkewSettings(exit_radius_difference = 2.0e-4, rubber = 1.0),
    "idler springs 1.8 and 1.2 N" => SkewSettings(idler_forces = (1.8, 1.2)),
    "sheet 1.5 mm off center in the stack" => SkewSettings(offset = 1.5e-3),
    "all three together" => SkewSettings(exit_radius_difference = 2.0e-4, idler_forces = (1.8, 1.2), offset = 1.5e-3),
    "all three, grippy paper" => SkewSettings(exit_radius_difference = 2.0e-4, idler_forces = (1.8, 1.2), offset = 1.5e-3, paper_paper = 0.6),
    "all three, worn O-rings" => SkewSettings(exit_radius_difference = 2.0e-4, idler_forces = (1.8, 1.2), offset = 1.5e-3, rubber = 1.0),
]

"""
    skew_report(design, build)

Runs the skew cases: the sheet's largest turn (degrees) and sideways drift (mm) on its way, and
its smallest clearance to the side plates (mm).
"""
function skew_report(d::FeederDesign = FeederDesign(), b::Build = Build())
    map(skew_cases()) do (name, s)
        poses = run!(SkewSim(d, b, s))
        turn = maximum(p -> abs(p.turn), poses)
        side = maximum(p -> abs(p.x), poses)
        # The sheet's corners across the path, turned, against the plates' inner faces.
        clear = minimum(p -> d.inner_width / 2 - (abs(p.x) * 1.0e3 + d.sheet_width / 2 * cosd(p.turn) + d.sheet_length / 2 * abs(sind(p.turn))), poses)
        (case = name, skew = round(turn; digits = 2), sideways = round(side * 1.0e3; digits = 1), clearance = round(clear; digits = 1))
    end
end
