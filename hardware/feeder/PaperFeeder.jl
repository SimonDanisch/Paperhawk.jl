"""
Design, simulation and CAD of Paperhawk's automatic sheet feeder.

    include("hardware/feeder/PaperFeeder.jl")
    using .PaperFeeder
    design = FeederDesign()
    sim = FeederSim(design, FeedSettings())
    frames = run!(sim)
    export_3mf(design, "feeder_h2d.3mf")   # Bambu Studio project of the printed parts
"""
module PaperFeeder

using LinearAlgebra
using GeometryBasics
using GLMakie
using Gmsh: gmsh
import MuJoCo
using Packing: GuillotinePacker
using ZipArchives: ZipWriter, zip_newfile, zip_writefile
import LibGEOS

export FeederDesign, Profile, path_length
export Paper, Shape, Friction, ContactModel, Motor, Roller, World, FeedSettings, FeederSim, Frame, Cycle, run!
export Drive, ThreeMotors, TwoMotors, OneMotor
export NipTest, run_nip, compare_nip
export SkewSettings, SkewSim
export Part, parts
export Bed, PrintObject, export_3mf
export PrintedPart, read_beads, section
export Build, Layout, Item, items, interference
export side_figure, side_view!, assembly!, assembly_figure, phone_view, animate, side_svg

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
include("print.jl")
include("printsim.jl")
include("printchecks.jl")
include("render.jl")

end
