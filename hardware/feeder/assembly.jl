# The whole feeder as a list of items: printed parts, bought parts and household parts, each
# with how to build it in Gmsh (in its assembled place), its material and how it lies on the
# print bed. Clearance checks, renders and print files all start from this list.

const X = Vec3d(1, 0, 0)

"""
    clips(d, b, l)

Every retaining clip, in the order the items list them: its name, the part with the groove it
sits in, that part's axis, the clip's low face `x`, the side it opens to and is pushed on toward
(`mouth`; down unless that way is blocked) and the `site` it belongs to. Each keeps a part beside it from sliding along: beside
the pick and feed rollers and outside the right arm, which holds those shafts in the arms
(`:pick`, `:feed`); on both sides of each exit and idler roller (`:exit_1`, `:exit_2`); outside
and inside the left plate on the driven exit shaft, whose right end floats on the motor's shaft
(`:drive_left`); inside both plates on the idler shaft (`:idle_ends`); on the left arm's post
outside the idler (`:idler`) and outside the feed cup gear (`:feed_out`).
"""
function clips(d::FeederDesign, b::Build, l::Layout)
    W2 = d.inner_width / 2
    o = W2 + b.plate
    G = GEAR_PLANES
    t = CLIP.thickness
    L = b.exit_roller_length
    list = @NamedTuple{name::String, shaft::String, center::Point2d, x::Float64, mouth::Vec2d, site::Symbol}[]
    clip(name, shaft, center, x, site; mouth = Vec2d(0, -1)) = push!(list, (; name, shaft, center, x, mouth, site))
    for (name, c) in (("pick", l.pick), ("feed", l.feed)), x in (-b.roller_length / 2 - 0.5 - t, b.roller_length / 2 + 0.5, o + G.arm[2] + 0.5)
        clip("$(name)_clip_$(round(Int, x))", "$(name)_shaft", c, x, Symbol(name))
    end
    # The lower exit shaft's clips go on from the front (+y), open toward the back: from above, the
    # driven shaft and the guides are in the way.
    from_front = Vec2d(-1, 0)
    for (k, xc) in enumerate(b.exit_rollers), x in (xc - L / 2 - 0.5 - t, xc + L / 2 + 0.5), (name, c) in (("drive", l.exit_up), ("idle", l.exit_low))
        clip("exit_$(name)_clip_$(round(Int, x))", "exit_$(name)_shaft", c, x, Symbol("exit_$k"); mouth = name == "idle" ? from_front : Vec2d(0, -1))
    end
    clip("exit_drive_clip_out", "exit_drive_shaft", l.exit_up, -o - 0.5 - t, :drive_left)
    clip("exit_drive_clip_in", "exit_drive_shaft", l.exit_up, -W2 + 0.5, :drive_left)
    for x in (-W2 + 0.5, W2 - 0.5 - t)
        clip("exit_idle_clip_$(round(Int, x))", "exit_idle_shaft", l.exit_low, x, :idle_ends; mouth = from_front)
    end
    clip("idler_clip", "arm_l", idler_center(l.gearbox, l.feed, l.pick), left_x(d, b, G.idler_clip + t), :idler)
    clip("feed_clip_out", "feed_shaft", l.feed, left_x(d, b, G.clip + t), :feed_out)
    return list
end

"""
    items(design = FeederDesign(), build = Build())

Every item of the feeder, in assembly order.
"""
function items(d::FeederDesign = FeederDesign(), b::Build = Build())
    l = Layout(d, b)
    p = l.profile
    W2 = d.inner_width / 2
    o = W2 + b.plate                       # outer faces at ±o
    out = Item[]
    add!(args...; kw...) = push!(out, Item(args...; kw...))
    plane(v::Vec2d) = Vec3d(0, v[1], v[2])
    flat = Vec3d(0, 0, -1)                 # D-shafts lie on their flat
    solid_fill = ["sparse_infill_density" => "100%"]
    all_clips = clips(d, b, l)
    clips_at!(site, group) = for c in filter(c -> c.site == site, all_clips)
        add!(c.name, :PETG, :gold, _ -> clip!(c.center, c.x, c.mouth); down = -X, size = 0.6, settings = solid_fill, group)
    end
    # A shaft with the grooves of its clips.
    grooved(tags, shaft) = foldl((t, c) -> cut!(t, groove(c.center, c.x, b.shaft / 2)), filter(c -> c.shaft == shaft, all_clips); init = tags)

    # Frame
    add!("side_plate_right", :PLA, :steelblue, _ -> side_plate!(d, b, l, 1); down = X, size = 3.0)
    add!("tray", :PLA, :slategray, _ -> tray!(d, b, l); down = plane(-p.normal), size = 3.0)
    add!("tray_leg", :PLA, :slategray, _ -> tray_leg!(d, b, l); down = Vec3d(0, -1, 0), size = 2.0)
    for side in (-1, 1)
        add!("lower_guide_$(side > 0 ? "r" : "l")", :PLA, :lightsteelblue, _ -> lower_guide!(d, b, l, side); down = side > 0 ? X : -X,
            settings = ["brim_type" => "outer_only", "brim_width" => "8"])
    end
    add!("upper_guide", :PLA, :lightsteelblue, _ -> upper_guide!(d, b, l); down = -X, settings = ["brim_type" => "outer_only", "brim_width" => "8"])
    add!("pad_bar", :PLA, :gray60, _ -> pad_bar!(d, b, l); down = Vec3d(0, 0, -1))
    for (k, c) in enumerate(l.ties[2:end])
        add!("tie_bar_$k", :PLA, :gray60, _ -> tie_bar!(d, b, c); down = Vec3d(0, 0, -1))
    end
    add!("side_plate_left", :PLA, :steelblue, _ -> side_plate!(d, b, l, -1); down = -X, size = 3.0)
    for (k, c) in enumerate(l.ties), side in (-1, 1)
        build = side > 0 ? (_ -> wedge!(b, c, o)) : (_ -> mirror_x!(wedge!(b, c, o)))
        add!("wedge_$(k)_$(side > 0 ? "r" : "l")", :PLA, :gray40, build; down = Vec3d(0, 0, -1), size = 1.0)
    end

    # Feed and pick shaft. The feed shaft turns in the plates; the pick shaft swings in their arc
    # slots, carried by the arms outside them. Clips beside the rollers keep them on their shafts,
    # clips outside the right arm keep the shafts in the arms.
    G = GEAR_PLANES
    t = CLIP.thickness
    right_end = o + G.arm[2] + 0.5 + t + 2.0
    add!("feed_shaft", :PLA, :silver, _ -> grooved(shaft!(b, l.feed, left_x(d, b, G.clip + t + 2.0), right_end), "feed_shaft");
        down = flat, size = 1.5, settings = solid_fill, group = :shafts)
    add!("pick_shaft", :PLA, :silver, _ -> grooved(shaft!(b, l.pick, left_x(d, b, G.pick + 13.5), right_end), "pick_shaft");
        down = flat, size = 1.5, settings = solid_fill, group = :shafts)
    for (name, c) in (("pick", l.pick), ("feed", l.feed))
        add!("$(name)_hub", :PLA, :darkorange, _ -> ring_hub!(b, c, -b.roller_length / 2, b.roller_length; radius = d.pick_radius, rings = 3);
            down = -X, size = 1.0, settings = solid_fill, group = :shafts)
        clips_at!(Symbol(name), :shafts)
    end
    # Driven exit shaft: the exit motor's shaft goes into a socket in its right end.
    add!("exit_drive_shaft", :PLA, :silver, _ -> grooved(exit_drive_shaft!(b, l, -o - 0.5 - t - 2.0, o - BYJ48.boss_height - 0.2, o), "exit_drive_shaft");
        down = flat, size = 1.5, settings = solid_fill, group = :shafts)
    add!("exit_idle_shaft", :PLA, :silver, _ -> grooved(shaft!(b, l.exit_low, -o - 10, o + 10), "exit_idle_shaft"); down = flat, size = 1.5,
        settings = solid_fill, group = :shafts)
    L = b.exit_roller_length
    for (k, xc) in enumerate(b.exit_rollers)
        add!("exit_hub_$k", :PLA, :darkorange, _ -> ring_hub!(b, l.exit_up, xc - L / 2, L; radius = d.exit_radius, rings = 2);
            down = -X, size = 1.0, group = :shafts)
        add!("exit_idler_$k", :PLA, :gray80, _ -> ring_hub!(b, l.exit_low, xc - L / 2, L; radius = d.exit_radius, rings = 2);
            down = -X, size = 1.0, group = :shafts)
        clips_at!(Symbol("exit_$k"), :shafts)
    end
    clips_at!(:drive_left, :shafts)
    clips_at!(:idle_ends, :shafts)
    for side in (-1, 1)
        add!("idler_spring_$(side > 0 ? "r" : "l")", :PETG, :yellowgreen, loaded -> idler_spring!(d, b, l, side; loaded);
            down = side > 0 ? X : -X, size = 1.0, settings = solid_fill, group = :springs)
    end

    # Pad
    add!("pad_spring", :PETG, :yellowgreen, loaded -> pad_spring!(d, b, l; force = PAD_FORCE, loaded); down = pad_down(d, l, PAD_FORCE),
        size = 1.0, settings = solid_fill, group = :springs)
    add!("pad_pin", :PLA, :gray40, _ -> pad_pin!(d, l); down = Vec3d(0, 0, -1), size = 0.6, group = :springs)
    for f in (0.8, 1.0)                    # spare springs to tune the pad force: print if needed
        add!("pad_spring_$(f)N", :PETG, :yellowgreen, loaded -> pad_spring!(d, b, l; force = f, loaded); down = pad_down(d, l, f),
            size = 1.0, settings = solid_fill, group = :variants)
    end
    add!("cork_strip", :household, :burlywood, _ -> cork!(d, l); group = :springs)

    # Pick arm: a link on each side outside the plates, swinging about the feed shaft; the left one
    # carries the idler between the two cup gears.
    for side in (-1, 1)
        add!("arm_$(side > 0 ? "r" : "l")", :PLA, :darkorange, _ -> arm!(d, b, l, side); down = side > 0 ? -X : X, size = 1.0,
            settings = solid_fill, group = :drives)
    end
    g = l.gearbox
    phases = gear_phases(g, l.feed, l.pick)
    add!("idler", :PETG, :yellowgreen, _ -> idler!(d, b, l); down = -X, size = 0.6, settings = solid_fill, group = :drives)
    clips_at!(:idler, :drives)

    # Gearbox: the motor turns the feed gear; feed and pick roller run behind freewheels.
    for (name, c, gear, phase, u) in (("feed", l.feed, g.feed, phases[2], G.feed), ("pick", l.pick, g.pick, phases[4], G.pick))
        add!("$(name)_ratchet", :PLA, :darkorange, _ -> ratchet!(b, c, left_x(d, b, u + 6.75), 6.5; spin = 1);
            down = -X, size = 0.6, settings = solid_fill, group = :drives)
        # Prints standing on its hub: the pocket with the pawl opens upward.
        add!("$(name)_cup_gear", :PETG, :yellowgreen, _ -> cup_gear!(b, c, left_x(d, b, u), 1; gear, phase, spin = 1);
            down = -X, size = 0.6, settings = solid_fill, group = :drives)
    end
    clips_at!(:feed_out, :drives)
    add!("pinion_stop", :PLA, :gray40, _ -> pinion_stop!(d, b, l); down = -X, size = 0.6, group = :drives)
    add!("drive_pinion", :PLA, :tomato, _ -> pinion!(d, b, g); down = -X, size = 0.6, settings = solid_fill, group = :drives)
    add!("drive_bracket", :PLA, :steelblue, _ -> motor_bracket!(b, g.motor, -o, -1; turn = g.turn, standoff = G.face, reach = g.reach);
        down = -X, size = 1.0, group = :drives)
    mface = -(o + G.face)
    add!("drive_motor", :bought, :gray25, _ -> byj48!(g.motor, mface, -1; turn = g.turn); group = :drives)
    for (k, h) in enumerate(byj48_holes(g.motor, g.turn))
        # Through lug and bracket face, ending flush with the face's inner side.
        shank = BYJ48.lug_thickness + 3.0
        add!("drive_lug_pin_$k", :PLA, :gray40, _ -> lug_pin!(h, mface - BYJ48.lug_thickness + shank, -1; shank);
            down = -X, size = 0.5, group = :drives)
    end
    add!("exit_motor", :bought, :gray25, _ -> byj48!(l.exit_up, o, 1; turn = l.exit_turn); group = :drives)
    for (k, h) in enumerate(byj48_holes(l.exit_up, l.exit_turn))
        add!("exit_lug_pin_$k", :PLA, :gray40, _ -> lug_pin!(h, o + BYJ48.lug_thickness - 7.0, 1; shank = 7.0); down = X, size = 0.5, group = :drives)
    end
    for (name, c, x0, rings) in (("pick", l.pick, -b.roller_length / 2, 3), ("feed", l.feed, -b.roller_length / 2, 3),
                                  ("exit_1", l.exit_up, b.exit_rollers[1] - L / 2, 2), ("exit_2", l.exit_up, b.exit_rollers[2] - L / 2, 2),
                                  ("idler_1", l.exit_low, b.exit_rollers[1] - L / 2, 2), ("idler_2", l.exit_low, b.exit_rollers[2] - L / 2, 2))
        len = name in ("pick", "feed") ? b.roller_length : L
        r = name in ("pick", "feed") ? d.pick_radius : d.exit_radius
        add!("$(name)_orings", :bought, :gray10, _ -> orings!(c, x0, len, r, rings); group = :shafts)
    end

    # The tolerance coupon to print first.
    add!("electronics_carrier", :PLA, :gray70, _ -> electronics_carrier!(d, b, l); down = Vec3d(0, 0, -1), size = 2.0, group = :frame)
    for bd in BOARDS
        add!(bd.name, :bought, bd.usb ? :royalblue : :seagreen, _ -> board!(d, l, bd); group = :electronics)
        add!("$(bd.name)_clamp", :PLA, :gray70, _ -> board_clamp!(d, l, bd); down = Vec3d(0, 0, 1), size = 1.0, group = :electronics)
    end
    add!("coupon", :PLA, :tomato, _ -> coupon!(b; origin = Point2d(-150.0, 120.0), x0 = o + 100); down = -X, size = 0.8, group = :coupon)
    add!("coupon_shaft", :PLA, :tomato, _ -> coupon_shaft!(b; origin = Point2d(-150.0, 100.0), x0 = o + 100); down = Vec3d(0, 0, -1),
        size = 0.8, group = :coupon)
    add!("coupon_clip", :PETG, :gold, _ -> clip!(Point2d(-150.0, 100.0), o + 142, Vec2d(0, -1)); down = -X, size = 0.6, settings = solid_fill,
        group = :coupon)
    return out
end

"""
The driven exit shaft: a D-shaft whose right end holds the exit motor's shaft in a socket. The
motor's face lies on the plate's outer face at x = `face`.
"""
function exit_drive_shaft!(b::Build, l::Layout, x0, x1, face)
    return cut!(shaft!(b, l.exit_up, x0, x1), motor_socket(l.exit_up, face, -1; play = b.socket))
end

"Mirrors solids across the plane x = 0."
function mirror_x!(tags)
    occ().mirror(tags, 1, 0, 0, 0)
    return tags
end

"Pin that holds the pad spring's root block in the pad bar."
pad_pin!(d::FeederDesign, l::Layout) = pad_pin_axis(l.profile, l, LUG_PIN / 2; half = 5.8)

"The cork strip on the pad head's curved face."
function cork!(d::FeederDesign, l::Layout)
    p = l.profile
    h = PAD_HEAD
    outer = [pad_face(p, d, u, d.pad_radius) for u in range(h.u0, h.u1; length = 16)]
    inner = [pad_face(p, d, u, d.pad_radius - h.cork) for u in range(h.u1, h.u0; length = 16)]
    return prism(vcat(outer, inner), -d.pad_width / 2, d.pad_width)
end

"NBR O-rings in a hub's grooves, as tori, standing out to `radius`."
function orings!(c::Point2d, x0, length, radius, rings; cord = 2.5)
    pitch = length / rings
    out = Tuple{Int32, Int32}[]
    for k in 1:rings
        xc = x0 + (k - 0.5) * pitch
        push!(out, (3, occ().addTorus(xc, c[1], c[2], radius - cord / 2, cord / 2, -1, 2π, [1.0, 0.0, 0.0])))
    end
    return out
end

# --- display -----------------------------------------------------------------------------------

"How a pad spring for `force` lies on the print bed: on its leaf's back face."
function pad_down(d::FeederDesign, l::Layout, force)
    p = l.profile
    u0, u1 = l.pad_leaf
    a = at_nip(p, u0, l.pad_depth) + deflection(PAD_LEAF, force) * left(p.entry)
    v = pad_back(p, a, at_nip(p, u1, l.pad_depth))
    return Vec3d(0, v[1], v[2])
end

"""
    parts(design = FeederDesign(), build = Build(); dir = nothing)

Every item of the feeder as a display mesh in its assembled place, and with `dir` its print
files (`PrintSim.parts`).
"""
PrintSim.parts(d::FeederDesign, b::Build = Build(); dir = nothing) = parts(items(d, b); dir)

"""
    export_3mf(design, path; build = Build(), groups = nothing, kw...)

The feeder's printed items as a Bambu Studio project (`PrintSim.export_3mf`); `groups` limits
the export, e.g. to `(:coupon,)` for the tolerance coupon.
"""
PrintSim.export_3mf(d::FeederDesign, path; build = Build(), groups = nothing, kw...) =
    export_3mf(filter(it -> groups === nothing || it.group in groups, items(d, build)), path; kw...)
