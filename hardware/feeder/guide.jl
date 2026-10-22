# The feeder's assembly pictures (PrintSim's `assembly_guide`): its bought parts' materials and
# CAD models, its leads, and the picture of the whole machine for the README.
#
#     studio = feeder_studio()
#     feeder_guide(studio, "hardware/feeder/assembly")
#     machine_picture(studio, "hardware/feeder/assembly/feeder.jpg")

"The bought and household parts, by name: NBR O-rings, the motors' steel cans, solder-masked boards, cork, paper."
bought_materials() = [
    r"_orings$" => Hikari.CoatedDiffuse(reflectance = (0.03f0, 0.03f0, 0.03f0), roughness = 0.6f0),
    r"_motor$" => Hikari.Conductor(eta = (1.6f0, 1.6f0, 1.52f0), k = (1.6f0, 1.6f0, 1.52f0), roughness = 0.15f0),
    r"^uln2003_(drive|exit)$" => Hikari.CoatedDiffuse(reflectance = (0.02f0, 0.16f0, 0.05f0), roughness = 0.15f0),
    r"^esp32$" => Hikari.CoatedDiffuse(reflectance = (0.02f0, 0.02f0, 0.025f0), roughness = 0.15f0),
    r"^cork_strip$" => Hikari.Diffuse(Kd = linear.((0.76f0, 0.6f0, 0.42f0))),
    r"^paper$" => Hikari.Diffuse(Kd = (0.8f0, 0.8f0, 0.78f0)),
]

"""
CAD models of the bought parts that others drew, for the pictures only: the checks use the
parts as `byj48!` and `board!` draw them from the datasheets and listings. Where each model
comes from and who made it.
"""
const BOUGHT_MODELS = (
    motor = (url = "https://raw.githubusercontent.com/FreeCAD/FreeCAD-library/master/Electrical%20Parts/Motors/Stepper/28BYJ-48/28BYJ-48_Stepper_Motor.step",
        credit = "28BYJ-48 by Charles Fox, FreeCAD library, CC-BY 3.0"),
    driver = (url = "https://raw.githubusercontent.com/escornabot/3dmodel/master/Brivoi/STEP/DriverBoard_ULN2003.step",
        credit = "ULN2003 driver board from the escornabot project, MIT"),
    esp32 = (url = "https://files.printables.com/media/prints/ac1e37ea-fb95-46fc-a976-0082f7272286/stls/13662032_4e6e2d86-2ad1-4e2a-8c63-b3182e301113_dd0a7d8d-dbb3-419f-90b2-772f19fc41b1/usb-c_esp32_30pinpin.step",
        credit = "ESP32 DevKit V1, 30 pins, USB-C, by Josselin Hefti on Printables, CC0"),
)

"Rotation and shift that put the motor model (body along +z, shaft at +y 8 mm, mounting face at z = 19) where `byj48!` puts a motor."
function motor_pose(c::Point2d, face, outward, turn::Vec2d)
    Y = Vec3d(0, -turn[1], -turn[2])
    Z = Vec3d(-outward, 0, 0)
    R = hcat(cross(Y, Z), Y, Z)
    return p -> R * (p - Vec3d(0, 8, 19)) + Vec3d(face, c[1], c[2])
end

"""
    bought_models(d, b)

The bought parts' CAD models (`BOUGHT_MODELS`) in place, by item name: both motors, both driver
boards and the ESP32. The driver board's model is one solid: its board is drawn green, what
stands on it black.
"""
function bought_models(d::FeederDesign, b::Build)
    l = Layout(d, b)
    g = l.gearbox
    o = d.inner_width / 2 + b.plate
    motor = downloaded(BOUGHT_MODELS.motor.url, "cad")
    models = Dict{String, Vector{Pair{GeometryBasics.Mesh, RGBf}}}(
        "drive_motor" => step_meshes(motor, motor_pose(g.motor, -(o + GEAR_PLANES.face), -1, g.turn)),
        "exit_motor" => step_meshes(motor, motor_pose(l.exit_up, o, 1, l.exit_turn)))
    green, black = RGBf(0.05, 0.38, 0.12), RGBf(0.06, 0.06, 0.07)
    # The board's own faces lie at most 1.55 mm above its underside; parts stand higher.
    board_face(m, f) = all(coordinates(m)[i][3] <= 1.55 for i in f)
    by_height(m, placed) = [GeometryBasics.mesh(coordinates(placed), filter(f -> board_face(m, f) == pcb, faces(placed)); normal = normals(placed)) => c
        for (pcb, c) in ((true, green), (false, black))]
    for bd in BOARDS
        f = board_frame(d, l, bd)
        C = Vec3d(f.center[1], f.center[2], f.shelf)
        models[bd.name] = bd.usb ?
            step_meshes(downloaded(BOUGHT_MODELS.esp32.url, "cad"), p -> p - Vec3d(12.065, 23.375, -1.6) + C) :
            step_meshes(downloaded(BOUGHT_MODELS.driver.url, "cad"), p -> p + C; color = by_height)
    end
    return models
end

"""
    machine_picture(st, path; design, build, ps, size = (1600, 1000), fov = 30, stack = 30, eye, lookat)

The assembled feeder with its leads and `stack` sheets in the tray, seen from `eye` toward
`lookat` and framed to fill the picture: the picture at the top of the README.
"""
function machine_picture(st::Studio, path; design = FeederDesign(), build = Build(), ps = parts(design, build),
        size = (1600, 1000), fov = 30, stack = 30, eye = Vec3f(-560, -640, 420), lookat = Vec3f(0, -80, 80))
    s = AssemblyStep("", ""; base = r".*", eye, lookat)
    shown = assembled(ps)
    paper = Part("paper", stack_mesh(design, Profile(design); stack), RGBAf(0.95, 0.95, 0.93, 1), :household)
    fig = Figure(; size, figure_padding = 0)
    ax = LScene(fig[1, 1]; show_axis = false, scenekw = (; lights = [environment(st, s)]))
    for q in vcat(shown, paper), (m, look) in looks(st, q, true)
        mesh!(ax, m; material = look)
    end
    for r in cable_routes(design, build, Layout(design, build))
        mesh!(ax, tube(r.points, 2.5); material = plastic(st.lead, 0.25f0))
    end
    focus = reduce(vcat, [sample_points(q.mesh) for q in shown])
    framed = framing(s, focus, Vec3f[]; fov, aspect = /(widths(viewport(ax.scene)[])...), fill = 0.9)
    camera_and_desk!(st, ax, framed, [(q.mesh, Vec3f(0)) for q in shown]; fov)
    return save_picture(st, path, fig)
end

"""
    feeder_studio(; kw...)

PrintSim's `Studio` for the feeder: its bought parts in their materials and as their makers'
CAD models, the desk under the frame. `kw` sets anything else (`samples`, ...).
"""
feeder_studio(; design = FeederDesign(), build = Build(), kw...) =
    Studio(; bought = bought_materials(), models = bought_models(design, build), center = Vec3f(0, -120, 60), kw...)

"Each motor's lead as the pictures draw it, framed with the motor and its driver board."
feeder_leads(d::FeederDesign, b::Build) = [Lead(r.motor, Vec3f.(r.points), ["$(r.motor)_motor", r.board]) for r in cable_routes(d, b, Layout(d, b))]

"""
    feeder_guide(st, dir; design, build, ps, steps = all, kw...)

The feeder's assembly instructions: a picture of every step of `assembly_steps` in `dir` and
`ASSEMBLY.md` next to it (`PrintSim.assembly_guide`).
"""
function feeder_guide(st::Studio, dir; design = FeederDesign(), build = Build(), ps = parts(design, build), steps = nothing, kw...)
    intro = """In each picture the parts of that step are in full color, pulled out along the way they go
in, with a red arrow to where they go; parts from earlier steps are paler. Wiring and the
first start: [ELECTRONICS.md](ELECTRONICS.md). Back to the [overview](README.md)."""
    return assembly_guide(st, dir, assembly_steps(design, build), assembled(ps); leads = feeder_leads(design, build), steps,
        title = "Assembling the sheet feeder", intro, kw...)
end
