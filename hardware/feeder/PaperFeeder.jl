"""
Design, simulation and CAD of Paperhawk's automatic sheet feeder. Print files, the print
simulation, the GPU checks and the assembly pictures come from PrintSim, with the feeder's
items, joints and assembly steps.

    include("dev/Paperhawk/hardware/feeder/PaperFeeder.jl")
    using .PaperFeeder, PrintSim
    design = FeederDesign()
    sim = FeederSim(design, FeedSettings())
    frames = run!(sim)
    export_3mf(design, "feeder_h2d.3mf")   # Bambu Studio project of the printed parts
    c = RayChecks(design)
    interference(c), motion_check(c), sequence_check(c, design)
"""
module PaperFeeder

using LinearAlgebra
using GeometryBasics
using GLMakie
using Gmsh: gmsh
import MuJoCo
import LibGEOS
import Hikari
using PrintSim
using PrintSim: GEOS, PointCache, extrude_loop, convex_hull, face_normals_per_vertex, fuse_all!, closed_surface, moved_box, box, overlaps,
    drift, plan, z_extent, polygons, part_section, profile_drift, moved, turned, overlap, gap, disk, rect, radii,
    downloaded, linear, plastic, looks, environment, framing, camera_and_desk!, save_picture, sample_points, tube

export FeederDesign, Profile, path_length
export Paper, Shape, Friction, ContactModel, Motor, Roller, World, FeedSettings, FeederSim, Frame, Cycle, run!
export Drive, ThreeMotors, TwoMotors, OneMotor
export NipTest, run_nip, compare_nip
export SkewSettings, SkewSim
export Build, Layout, items
export motion_check, insertion_check, electronics_check, cable_route_check
export side_figure, side_view!, assembly!, assembly_figure, phone_view, animate, side_svg
export feeder_studio, feeder_guide, machine_picture

include("design.jl")
include("physics.jl")
include("simulation.jl")
include("validate.jl")
include("envelope.jl")
include("cad.jl")
include("mechanics.jl")
include("assembly.jl")
include("checks.jl")
include("skew.jl")
include("printchecks.jl")
include("render.jl")
include("guide.jl")

end
