# Makie views of the profile, the simulation and the CAD assembly.

const SHEET_COLORS = [:royalblue, :darkorange, :seagreen, :crimson, :purple, :goldenrod, :teal, :sienna]

sheet_color(k) = SHEET_COLORS[mod1(k, length(SHEET_COLORS))]

"Static surfaces of the feeder as polylines in millimeters."
function outline(d::FeederDesign)
    p = Profile(d)
    lines = Vector{Point2d}[]
    push!(lines, vcat([p.tray.a], points(p.fillet), [p.ramp.b]))
    foreach(piece -> push!(lines, points(piece)), vcat(p.lower_guide, p.upper_guide))
    push!(lines, reduce(vcat, [[l.a, l.b] for l in p.box]))
    return lines
end

circle_points(c, r; n = 64) = [Point2d(c + r * Vec2d(cos(φ), sin(φ))) for φ in range(0, 2π; length = n)]

"""
    side_view!(ax, sim, frame)

Draws the feeder's side profile, rollers and sheets of one recorded frame into `ax`, in
millimeters.
"""
function side_view!(ax, sim::FeederSim, frame::Frame; linewidth = 2)
    for l in outline(sim.design)
        lines!(ax, l; color = :gray30, linewidth = 1.5)
    end
    pile = sim.settings.pile * 1.0e3
    lines!(ax, [Point2d(0, pile), Point2d(sim.design.box_length, pile)]; color = :gray60, linestyle = :dash)
    for (r, lift, angle) in zip(rollers(sim), frame.lifts, frame.angles)
        c = (r.home + lift * r.axis) * 1.0e3
        R = r.radius * 1.0e3
        pad = r.name == :pad
        poly!(ax, circle_points(c, R); color = pad ? (:sienna, 0.6) : (:gray20, 0.5), strokewidth = 0)
        pad || lines!(ax, [Point2d(c), Point2d(c + R * Vec2d(cos(angle), sin(angle)))]; color = :white, linewidth = 1.5)
    end
    scatter!(ax, [Point2d(sim.gate * 1.0e3)]; color = :red, markersize = 6)
    for (k, pts) in enumerate(frame.sheets)
        lines!(ax, [Point2d(q * 1.0e3) for q in pts]; color = sheet_color(k), linewidth)
    end
    return ax
end

"""
    side_figure(sim, frame; zoom = 12)

Side view of the whole feeder next to a close-up of the nip, `zoom` millimeters around it.
"""
function side_figure(sim::FeederSim, frame::Frame; zoom = 12.0, size = (1400, 800))
    fig = Figure(; size)
    ax = Axis(fig[1, 1]; aspect = DataAspect(), title = "t = $(round(frame.t; digits = 2)) s   $(frame.phase)")
    side_view!(ax, sim, frame)
    nip = Profile(sim.design).nip
    zx = Axis(fig[1, 2]; aspect = DataAspect(), title = "nip")
    side_view!(zx, sim, frame; linewidth = 1.5)
    limits!(zx, nip[1] - zoom, nip[1] + zoom, nip[2] - zoom, nip[2] + zoom)
    colsize!(fig.layout, 2, Relative(0.4))
    return fig
end

# --- 3D views of the assembly ------------------------------------------------------------------

"Mi 10T main camera: field of view along the long and the short side of its 4:3 image, degrees."
const PHONE_FOV = (long = 67.0, short = 53.0)

"A sheet's side-profile polyline (meters) as a ribbon across the sheet width, in millimeters."
function ribbon(pts::Vector{Vec2d}, width)
    pos = [Point3f(x, p[1] * 1.0e3, p[2] * 1.0e3) for p in pts for x in (-width / 2, width / 2)]
    faces = GLTriangleFace[]
    for i in 1:(length(pts) - 1)
        a, b, c, e = 2i - 1, 2i, 2i + 1, 2i + 2
        push!(faces, GLTriangleFace(a, b, c), GLTriangleFace(b, e, c))
    end
    return GeometryBasics.mesh(pos, faces; normal = face_normals_per_vertex(pos, faces))
end

"Box spanned by the edges `a`, `b`, `c` from corner `o`."
function slab(o::Point3f, a::Vec3f, b::Vec3f, c::Vec3f)
    corners = [o, o + a, o + a + b, o + b, o + c, o + a + c, o + a + b + c, o + b + c]
    quads = ((1, 4, 3, 2), (5, 6, 7, 8), (1, 2, 6, 5), (2, 3, 7, 6), (3, 4, 8, 7), (4, 1, 5, 8))
    pos = Point3f[]
    faces = GLTriangleFace[]
    for q in quads
        k = length(pos)
        append!(pos, corners[collect(q)])
        push!(faces, GLTriangleFace(k + 1, k + 2, k + 3), GLTriangleFace(k + 1, k + 3, k + 4))
    end
    return GeometryBasics.mesh(pos, faces; normal = face_normals_per_vertex(pos, faces))
end

lift3(p::Point2d, x = 0.0) = Point3f(x, p[1], p[2])
lift3(v::Vec2d) = Vec3f(0, v[1], v[2])

"The paper stack in the tray, `stack` sheets lying on it with their edges against the ramp."
function stack_mesh(d::FeederDesign, p::Profile; stack = 20)
    w = Float32(d.sheet_width)
    return slab(lift3(p.foot, -w / 2), Vec3f(w, 0, 0), -Float32(d.sheet_length) * lift3(p.down), Float32(stack * 0.1) * lift3(p.normal))
end

"Lens position and the corners of what the phone sees on a plane at height `z`."
function phone_frustum(d::FeederDesign; z = 0.0)
    lens = Point3f(0, d.box_length / 2, d.camera_height)
    h = d.camera_height - z
    dy, dx = h * tand(PHONE_FOV.long / 2), h * tand(PHONE_FOV.short / 2)
    corners = [Point3f(sx * dx, d.box_length / 2 + sy * dy, z) for (sx, sy) in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
    return lens, corners
end

"""
    assembly!(scene, design, parts; frame = nothing, sim = nothing, stack = 50, pile = 0.0)

All parts, the paper stack in the tray, the pile in the box (`pile` mm high), the sheets of a
simulation frame and the phone's field of view.
"""
function assembly!(ax, d::FeederDesign, ps::Vector{Part}; frame = nothing, stack = 20, pile = 0.0, frustum = true)
    p = Profile(d)
    for part in ps
        mesh!(ax, part.mesh; color = part.color, transparency = part.color.alpha < 1, backlight = 1.0f0)
    end
    paper = RGBAf(0.97, 0.97, 0.94, 1)
    mesh!(ax, stack_mesh(d, p; stack); color = paper, backlight = 1.0f0)
    pile > 0 && mesh!(ax, slab(Point3f(-105, 4, 0), Vec3f(210, 0, 0), Vec3f(0, 297, 0), Vec3f(0, 0, pile)); color = paper, backlight = 1.0f0)
    if frame !== nothing
        for (k, pts) in enumerate(frame.sheets)
            mesh!(ax, ribbon(pts, d.sheet_width); color = (sheet_color(k), 0.85), backlight = 1.0f0)
        end
    end
    if frustum
        lens, corners = phone_frustum(d; z = pile)
        for c in corners
            lines!(ax, [lens, c]; color = (:gold, 0.8), linewidth = 1.5)
        end
        lines!(ax, vcat(corners, corners[1:1]); color = (:gold, 0.8), linewidth = 1.5)
    end
    return ax
end

"""
    assembly_figure(design, parts; eye, lookat, size, kwargs...)

The assembly from a viewpoint, rendered with GLMakie.
"""
function assembly_figure(d::FeederDesign, ps::Vector{Part}; eye = Vec3f(560, 520, 430), lookat = Vec3f(0, 40, 110),
        size = (1600, 1100), kwargs...)
    fig = Figure(; size, backgroundcolor = :white)
    ax = LScene(fig[1, 1]; show_axis = false)
    assembly!(ax, d, ps; kwargs...)
    cam = Makie.cam3d!(ax.scene; eyeposition = eye, lookat, upvector = Vec3f(0, 0, 1), fov = 30)
    update_cam!(ax.scene, cam, eye, lookat, Vec3f(0, 0, 1))
    return fig
end

"""
    phone_view(design, parts; pixels = 1200, kwargs...)

What the phone sees: the scene from its lens with the main camera's field of view, the image's
long side along the box.
"""
function phone_view(d::FeederDesign, ps::Vector{Part}; pixels = 1200, kwargs...)
    fig = Figure(; size = (pixels, round(Int, pixels * 3 / 4)), backgroundcolor = :black, figure_padding = 0)
    ax = LScene(fig[1, 1]; show_axis = false)
    assembly!(ax, d, filter(p -> p.name != "phone", ps); frustum = false, kwargs...)
    lens, _ = phone_frustum(d)
    eye = Vec3f(lens)
    lookat = eye - Vec3f(0, 0, 1)
    cam = Makie.cam3d!(ax.scene; eyeposition = eye, lookat, upvector = Vec3f(1, 0, 0), fov = PHONE_FOV.short,
        near = 1.0f0, far = 2000.0f0, projectiontype = Makie.Perspective)
    update_cam!(ax.scene, cam, eye, lookat, Vec3f(1, 0, 0))
    return fig
end

# --- animation ---------------------------------------------------------------------------------

"""
    animate(sim, frames, path; zoom = 15, framerate = 30, every = 2)

Side view video of a run: the whole feeder next to a close-up of the nip. Every `every`-th
recorded frame becomes a video frame.
"""
function animate(sim::FeederSim, frames::Vector{Frame}, path; zoom = 15.0, framerate = 30, every = 2, size = (1600, 820))
    index = Observable(1)
    frame = map(i -> frames[i], index)
    fig = Figure(; size)
    title = map(f -> "t = $(round(f.t; digits = 2)) s   $(f.phase)   max tension $(round(f.tension; digits = 2)) N", frame)
    ax = Axis(fig[1, 1]; aspect = DataAspect(), title)
    nip = Profile(sim.design).nip
    zx = Axis(fig[1, 2]; aspect = DataAspect(), title = "nip")
    limits!(zx, nip[1] - zoom, nip[1] + zoom, nip[2] - zoom, nip[2] + zoom)
    colsize!(fig.layout, 2, Relative(0.38))
    for a in (ax, zx)
        for l in outline(sim.design)
            lines!(a, l; color = :gray30, linewidth = 1.5)
        end
        pile = sim.settings.pile * 1.0e3
        lines!(a, [Point2d(0, pile), Point2d(sim.design.box_length, pile)]; color = :gray60, linestyle = :dash)
        for (j, r) in enumerate(rollers(sim))
            c = map(f -> (r.home + f.lifts[j] * r.axis) * 1.0e3, frame)
            R = r.radius * 1.0e3
            pad = r.name == :pad
            poly!(a, map(c -> circle_points(c, R), c); color = pad ? (:sienna, 0.6) : (:gray20, 0.5), strokewidth = 0)
            pad || lines!(a, map((c, f) -> [Point2d(c), Point2d(c + R * Vec2d(cos(f.angles[j]), sin(f.angles[j])))], c, frame);
                color = :white, linewidth = 1.5)
        end
        scatter!(a, [Point2d(sim.gate * 1.0e3)]; color = :red, markersize = 6)
        for k in eachindex(sim.fed_at)
            lines!(a, map(f -> [Point2d(q * 1.0e3) for q in f.sheets[k]], frame); color = sheet_color(k), linewidth = a === ax ? 2 : 1.5)
        end
    end
    record(fig, path, 1:every:length(frames); framerate) do i
        index[] = i
    end
    return path
end

# --- SVG side view, without a GPU --------------------------------------------------------------

"""
    side_svg(path, sim; window = nothing, scale = 4)

Writes the simulation's current state as an SVG side view: walls, guides, rollers, the pad
and the sheets, in millimeters. `window = (ymin, ymax, zmin, zmax)` crops it.
"""
function side_svg(path, sim::FeederSim; window = nothing, scale = 4)
    w = sim.world
    pts = reduce(vcat, [sheet_points(w, k) for k in 1:w.sheets]) .* 1.0e3
    ymin, ymax, zmin, zmax = window === nothing ?
        (minimum(first.(pts)) - 20, maximum(first.(pts)) + 20, minimum(last.(pts)) - 20, maximum(last.(pts)) + 20) : window
    W, H = (ymax - ymin) * scale, (zmax - zmin) * scale
    X(p) = round((p[1] * 1.0e3 - ymin) * scale; digits = 2)
    Y(p) = round((zmax - p[2] * 1.0e3) * scale; digits = 2)
    io = IOBuffer()
    println(io, """<svg xmlns="http://www.w3.org/2000/svg" width="$(round(Int, W))" height="$(round(Int, H))" viewBox="0 0 $W $H">""")
    println(io, """<rect width="100%" height="100%" fill="white"/>""")
    for o in w.walls
        println(io, """<line x1="$(X(o.a))" y1="$(Y(o.a))" x2="$(X(o.b))" y2="$(Y(o.b))" stroke="#555" stroke-width="2"/>""")
    end
    for a in vcat(w.concave, w.convex)
        φ = range(a.start, a.start + mod(a.stop - a.start, 2π); length = 64)
        ps = [a.center + a.radius * Vec2d(cos(t), sin(t)) for t in φ]
        println(io, """<polyline fill="none" stroke="#555" stroke-width="2" points="$(join(["$(X(p)),$(Y(p))" for p in ps], " "))"/>""")
    end
    colors = Dict(:pick => "#d62", :feed => "#d62", :pad => "#a70", :exit_low => "#d62", :exit_up => "#888")
    for r in w.rollers
        c = center(r)
        println(io, """<circle cx="$(X(c))" cy="$(Y(c))" r="$(r.radius * 1.0e3 * scale)" fill="none" stroke="$(get(colors, r.name, "#d62"))" stroke-width="2"/>""")
        tip = c + r.radius * Vec2d(cos(r.angle), sin(r.angle))
        println(io, """<line x1="$(X(c))" y1="$(Y(c))" x2="$(X(tip))" y2="$(Y(tip))" stroke="$(get(colors, r.name, "#d62"))"/>""")
    end
    palette = ["#1f77b4", "#2ca02c", "#9467bd", "#e377c2", "#17becf", "#bcbd22"]
    for k in 1:w.sheets
        ps = sheet_points(w, k)
        println(io, """<polyline fill="none" stroke="$(palette[mod1(k, length(palette))])" stroke-width="1.5" points="$(join(["$(X(p)),$(Y(p))" for p in ps], " "))"/>""")
    end
    println(io, """<text x="8" y="20" font-family="sans-serif" font-size="16">t = $(round(w.t; digits = 2)) s, $(sim.controller.phase)</text>""")
    println(io, "</svg>")
    write(path, take!(io))
    return path
end

# --- illustrated assembly instructions ------------------------------------------------------------

"""
    assembly_steps(design, build)

The assembly order with a camera for each step. Coordinates: x across the sheet (the gearbox
side is -x), y toward the box, z up. Until the left plate is on, the frame lies on its right
plate, so those steps look at it with -x up.
"""
function assembly_steps(d::FeederDesign, b::Build)
    l = Layout(d, b)
    p = l.profile
    g = l.gearbox
    G = GEAR_PLANES
    o = d.inner_width / 2 + b.plate
    v(q::Point2d, x = 0.0) = Vec3f(x, q[1], q[2])
    dir(n::Vec2d) = Vec3f(0, n[1], n[2])
    up = Vec3f(0, 0, 1)
    lying = Vec3f(-1, 0, 0)                     # the frame on its right plate: -x points up
    out = Vec3f(-1, 0, 0)                       # away from the left plate, into the gearbox
    gearbox = v(g.motor, left_x(d, b, 20.0))
    bar = v(l.pad_bar)
    arm = v(l.pick, -o - 10)
    leg = v(along(p, -d.tray_length + TRAY_LEG.at, -40.0))
    # Clips come from the side away from their mouth, 40 mm out.
    cs = clips(d, b, l)
    clipped(rx) = [Regex("^$(c.name)\$") => -40 * dir(c.mouth) for c in cs if occursin(rx, c.name)]
    return [
        AssemblyStep("Fit the O-rings",
            "Stretch three O-rings into the grooves of the pick hub and of the feed hub, and two onto each exit hub and each idler roller.";
            base = r"^pick_hub$", new = [r"^pick_orings$" => Vec3f(45, 0, 0)],
            eye = v(l.pick, 130) + Vec3f(0, 90, 60), lookat = v(l.pick, 20), kept = false, apart = true),
        AssemblyStep("Electronics onto the carrier",
            "Lay each board into its pocket on the carrier, parts up, onto the shelves under its corners: the drive motor's driver on the left, the exit motor's on the right, the ESP32 in between with its pins down and its USB port to the back. Wire them as in [ELECTRONICS.md](ELECTRONICS.md). Press a clamp frame onto each, its four pegs into the posts.";
            base = r"^electronics_carrier$", new = [r"^(uln2003_drive|uln2003_exit|esp32)$" => 35up, r"_clamp$" => 70up],
            eye = Vec3f(260, -330, 230), lookat = Vec3f(0, -52, 35), kept = false, apart = true),
        AssemblyStep("Inserts into the right side plate",
            "Lay the right side plate on the table, outer face down. Set the upper guide, the right half of the lower guide and the electronics carrier with its boards into its pockets.";
            base = r"^side_plate_right$", new = [r"^(lower_guide_r|upper_guide|electronics_carrier|uln2003_drive|uln2003_exit|esp32|.*_clamp)$" => Vec3f(-150, 0, 0)],
            moves = [r"^upper_guide$" => Vec3f(-150, 0, 0), r"^lower_guide_r$" => Vec3f(-150, 0, 0),
                r"^(electronics_carrier|uln2003_drive|uln2003_exit|esp32|.*_clamp)$" => Vec3f(-150, 0, 0)],
            eye = Vec3f(-640, -420, 520), lookat = Vec3f(-90, -40, 60), up = lying),
        # On the table, apart from the frame: there nothing is in the way of the spring's head.
        AssemblyStep("Separation pad",
            "Glue a 2 mm cork strip, cut lengthwise from a wine cork, onto the curved face of the pad spring's head. Slide the spring's root block into the open side of the pad bar's pocket, until the hole in the block lines up with the bar's hole, and press the pad pin through bar and block.";
            base = r"^pad_bar$", new = [r"^(pad_spring|cork_strip)$" => 45 * dir(p.entry), r"^pad_pin$" => 30 * dir(left(p.entry))],
            eye = bar + Vec3f(-360, 300, 260), lookat = bar, kept = false, apart = true),
        AssemblyStep("Bars and the lower guide's left half",
            "Push the pad bar with its spring, the head toward the front, and the two tie bars into the square holes of the right side plate. Then stand the left half of the lower guide end to end on the right half, its cut-out around the pad's head.";
            new = [r"^(pad_bar|pad_spring|cork_strip|pad_pin)$" => Vec3f(-150, 0, 0), r"^tie_bar_\d$" => Vec3f(-150, 0, 0),
                r"^lower_guide_l$" => Vec3f(-250, 0, 0)],
            eye = Vec3f(-760, -620, 600), lookat = Vec3f(-90, -30, 120), up = lying),
        AssemblyStep("Left side plate",
            "Lower the left side plate onto all inserts and bars, so the tenons come through its square holes.";
            new = [r"^side_plate_left$" => Vec3f(-120, 0, 0)],
            eye = Vec3f(-620, -520, 420), lookat = Vec3f(-60, -60, 120), up = lying),
        AssemblyStep("Wedges",
            "Stand the frame up. Drive a wedge through the slot of every tenon, six in all, until both plates sit tight on the bars' shoulders.";
            # Shown well out; a wedge goes in from where its tip meets the slot, 15 mm out.
            new = [r"^wedge_" => Vec3f(0, -75, 0)], moves = [r"^wedge_" => Vec3f(0, -40, 0)],
            eye = Vec3f(560, -380, 320), lookat = Vec3f(60, -50, 80)),
        AssemblyStep("Tray",
            "Slide the tray in from the back, face up, its edges in the long pockets of both plates, until its ramp stops against the pockets' front ends.";
            new = [r"^tray$" => 200 * dir(-p.down)],
            eye = Vec3f(520, -720, 420), lookat = Vec3f(0, -160, 100)),
        AssemblyStep("Tray stand",
            "Lift the tray's back end a little and set the stand under it, its two pegs into the holes in the tray's underside.";
            new = [r"^tray_leg$" => Vec3f(0, 0, -60)],
            eye = leg + Vec3f(420, -380, 160), lookat = leg),
        AssemblyStep("Feed roller",
            "Hold the feed hub under the upper guide's front end, lift the pad with a finger and push the feed shaft in from the left through both plates and the hub, the hub's flat inside lined up with the shaft's flat. Slide the hub between the two grooves near the shaft's middle and push a clip into each, beside the hub: a clip goes on sideways, open side first, and clicks into its groove.";
            base = r"^(feed_hub|feed_orings)$", new = [r"^feed_shaft$" => Vec3f(-300, 0, 0); clipped(r"^feed_clip_-?\d\d?$")],
            eye = v(l.feed, -560) + Vec3f(0, -300, 220), lookat = v(l.feed, -60)),
        AssemblyStep("Pick arm and roller",
            "Put an arm onto each end of the feed shaft, outside the plates, the left one with the post for the idler. Hold the pick hub over the tray and push the pick shaft in from the left: through the left arm, the arc slot in the left plate, the hub, the right plate's slot and the right arm. Slide the hub, its flat lined up with the shaft's, between the two grooves near the shaft's middle and push a clip into each, beside the hub. Push a clip into the groove of the pick shaft and of the feed shaft outside the right arm.";
            base = r"^(pick_hub|pick_orings)$", new = [r"^arm_l$" => Vec3f(-60, 0, 0); r"^arm_r$" => Vec3f(60, 0, 0);
                r"^pick_shaft$" => Vec3f(-320, 0, 0); clipped(r"^pick_clip_-?\d\d?$"); clipped(r"^(pick|feed)_clip_\d\d\d$")],
            eye = arm + Vec3f(-480, -420, 300), lookat = v(l.pick, -40)),
        AssemblyStep("Freewheels",
            "Push the pick ratchet onto the pick shaft's left end, its flat lined up with the shaft's, up to the arm, and slide the pick cup gear over it, pocket first, turning it back and forth until its pawl drops in front of a ratchet tooth. The same on the feed shaft, one plane further out: ratchet, feed cup gear, then a clip into the groove outside it. The pick cup gear needs no clip of its own: the feed cup gear covers its outer face and keeps it on its shaft with 0.5 mm of play.";
            new = [r"^pick_ratchet$" => 40out; r"^pick_cup_gear$" => 80out; r"^feed_ratchet$" => 70out; r"^feed_cup_gear$" => 110out;
                clipped(r"^feed_clip_out$")],
            eye = arm + Vec3f(-520, -260, 240), lookat = arm + Vec3f(-20, 20, 0)),
        AssemblyStep("Idler",
            "Slide the idler onto the left arm's post until its teeth mesh both cup gears (turn it a little if a tooth sits on a tooth) and push a clip into the groove at the post's end.";
            new = [r"^idler$" => 110out; clipped(r"^idler_clip$")],
            eye = arm + Vec3f(-520, -160, 320), lookat = arm + Vec3f(-20, 20, 30)),
        AssemblyStep("Exit rollers",
            "Push the driven exit shaft in from the right through both plates and both exit hubs, each hub's flat lined up with the shaft's; its right end stays flush with the plate. Slide each hub between its two grooves and push a clip into each, beside the hub, then a clip into the groove just inside the left plate and one into the groove outside it. Push the idler shaft in from the left through its slots and both idler rollers the same way; its clips go on from the front, beside each roller and just inside each plate. Then press the two idler springs into the outer faces of the plates so they push the idler shaft up.";
            base = r"^(exit_hub_\d|exit_\d_orings|exit_idler_\d|idler_\d_orings)$",
            new = [r"^exit_drive_shaft$" => Vec3f(300, 0, 0); r"^exit_idle_shaft$" => Vec3f(-300, 0, 0); clipped(r"^exit_(drive|idle)_clip_");
                r"^idler_spring_r$" => Vec3f(35, 0, 0); r"^idler_spring_l$" => Vec3f(-35, 0, 0)],
            eye = v(l.exit_up) + Vec3f(460, 420, 200), lookat = v(l.exit_up) + Vec3f(0, -20, -10)),
        AssemblyStep("Drive motor",
            "Press the pinion stop's peg into its hole in the left plate, beside the feed cup gear. Push the pinion onto the drive motor's shaft, its flat inside lined up with the shaft's flats. Pin the motor to its bracket with the two lug pins. Press the bracket's pegs into the left plate, the pinion's teeth into the feed cup gear; turn the pinion a little if a tooth sits on a tooth. The stop keeps the pinion on the motor's shaft.";
            new = [r"^pinion_stop$" => 45out, r"^drive_pinion$" => 85out, r"^drive_bracket$" => 135out, r"^drive_motor$" => 175out, r"^drive_lug_pin_\d$" => 210out],
            moves = [r"^pinion_stop$" => 45out, r"^drive_(pinion|bracket|motor|lug_pin_\d)$" => 60out],
            eye = gearbox + Vec3f(-480, 330, 280), lookat = gearbox + Vec3f(-90, 0, -10)),
        AssemblyStep("Exit motor",
            "Mount the exit motor straight onto the right plate: its shaft goes into the socket of the driven exit shaft, the lug pins into the plate.";
            new = [r"^exit_motor$" => Vec3f(70, 0, 0), r"^exit_lug_pin_\d$" => Vec3f(110, 0, 0)],
            eye = v(l.exit_up, 500) + Vec3f(0, 280, 160), lookat = v(l.exit_up, 150)),
        AssemblyStep("Drive motor's lead",
            "Lay the drive motor's lead outside the bracket: from its housing back past the motor and its lugs, down to the slot below the gears, then straight in through the slot and plug it into the left driver.";
            eye = Vec3f(-640, 60, 330), lookat = Vec3f(-140, -30, 70), leads = ["drive"]),
        AssemblyStep("Exit motor's lead",
            "Lay the exit motor's lead from the top of the motor around its back side and down to the slot near the bottom of the right plate, push the plug through and plug it into the right driver.";
            eye = Vec3f(560, -320, 330), lookat = Vec3f(122, -10, 80), leads = ["exit"]),
        AssemblyStep("Ready",
            "Stand the feeder behind the box so that it reaches over the box's back wall and plug the ESP32's USB cable in from the back, under the tray. Load paper: lift the pick roller by its shaft, slide the stack in face up until its top edge touches the ramp, and let the pick roller down onto it.";
            base = r".*", eye = Vec3f(-520, -560, 380), lookat = Vec3f(-20, -90, 90), leads = ["drive", "exit"]),
    ]
end

"The parts that go into the feeder: all but the fit coupon and the spare pad springs."
assembled(ps) = filter(q -> !occursin(r"^(coupon.*|pad_spring_\d)", q.name), ps)

