# The conditions the feeder has to handle, as 2D simulation runs: stack sizes, papers, the
# spread of friction and spring forces, weak motors, a filling box, and sheets that were folded,
# crumpled, cockled or curled. Every sheet of every case has to land in the box on its own.

"Office paper of `grammage` g/m²: 0.8 g/cm³, E ≈ 4 GPa."
function office_paper(grammage)
    t = 1.25e-6 * grammage
    return Paper(grammage = grammage * 1.0e-3, thickness = t, bending = 7.0e-5 * (t / 1.0e-4)^3, stretch = 8.4e4 * t / 1.0e-4)
end

"A letter folded in three and opened again: two creases of `angle` (rad)."
letter_fold(angle; hinge = 0.2) = Shape(creases = [(0.099, angle), (0.198, angle)]; hinge)

"Folded once across the middle and opened again."
half_fold(angle; hinge = 0.2) = Shape(creases = [(0.1485, angle)]; hinge)

"""
    crumpled(k; count = 8, angle = deg2rad(25))

Sheet `k` of a lightly crumpled batch: `count` soft creases of up to `angle` at irregular places
(a golden-ratio sequence, so every sheet differs and runs repeat) and 2 mm waves.
"""
function crumpled(k; count = 8, angle = deg2rad(25))
    φ = (sqrt(5) - 1) / 2
    creases = map(1:count) do j
        n = k * count + j
        (0.02 + 0.26 * mod(n * φ, 1.0), angle * (2 * mod(n * φ^2 * 7, 1.0) - 1))
    end
    return Shape(; creases, hinge = 0.3, waves = (0.002, 0.04))
end

"""
    case(stack; sheets = 4, kwargs...)

Settings for `stack` sheets in the tray: the top `sheets` of them simulated, two of them fed.
"""
function case(stack; sheets = 4, kwargs...)
    n = min(stack, sheets)
    return FeedSettings(; sheets = n, stack, cycles = min(n, 2), kwargs...)
end

"""
    envelope()

The cases as name => settings. Corners combine the spreads that push toward the same failure:
double feeds (grippy paper, slippery cork, weak pad, heavy pick arm), misfeeds (worn tires, light
arm, heavy grippy paper), stalls (weak motor and lossy gears against strong springs and a full box).
Paper on paper grips with 0.4 to 0.6 (static); NBR tires with 1.3 new and 1.0 worn; the cork pad
with 0.7 to 0.9. No friction feeder separates sheets that grip each other as hard as the pad
grips them, or picks paper that grips itself as hard as the tire grips it. The pick arm's weight
is a mass, not a spring: it varies only with the print's infill, ±10 %.
"""
function envelope()
    double = (paper_paper = Friction(0.6, 0.5), pad = Friction(0.7, 0.6), pad_force = 0.8, pick_weight = 0.8)
    misfeed = (rubber = Friction(1.0, 0.9), pick_weight = 0.65, paper_paper = Friction(0.6, 0.5), paper = office_paper(120))
    stall = (motor = 2.2, gear_efficiency = 0.8, pad_force = 1.0, pad = Friction(1.0, 0.9), idler_force = 3.66,
        pile = 0.015, paper = office_paper(120))
    flat = Shape()
    return [
        "1 sheet" => case(1),
        "2 sheets" => case(2),
        "4 sheets" => case(4),
        "10 sheets" => case(10),
        "40 sheets" => case(40),
        "60 g, 40 sheets" => case(40; paper = office_paper(60)),
        "60 g, 2 sheets" => case(2; paper = office_paper(60)),
        "120 g, 40 sheets" => case(40; paper = office_paper(120)),
        "120 g, 2 sheets" => case(2; paper = office_paper(120)),
        "double corner, 40" => case(40; double...),
        "double corner, 4" => case(4; double...),
        "double corner, 60 g, 40" => case(40; double..., paper = office_paper(60)),
        "misfeed corner, 40" => case(40; misfeed...),
        "misfeed corner, 2" => case(2; misfeed...),
        "stall corner, 40" => case(40; stall...),
        "stall corner, 2" => case(2; stall...),
        "slippery paper, 40" => case(40; paper_paper = Friction(0.35, 0.3)),
        "box pile 15 mm, 40" => case(40; pile = 0.015),
        "letter fold +40°" => case(10; shapes = [letter_fold(deg2rad(40))]),
        "letter fold -50°" => case(10; shapes = [letter_fold(deg2rad(-50))]),
        "letter fold +70°, soft" => case(10; shapes = [letter_fold(deg2rad(70); hinge = 0.05)]),
        "letter fold -40°, soft" => case(10; shapes = [letter_fold(deg2rad(-40); hinge = 0.05)]),
        "half fold +60°" => case(10; shapes = [half_fold(deg2rad(60))]),
        "half fold -30°" => case(10; shapes = [half_fold(deg2rad(-30))]),
        "creased head +45°" => case(10; shapes = [Shape(creases = [(0.015, deg2rad(45))])]),
        "creased head -35°" => case(10; shapes = [Shape(creases = [(0.015, deg2rad(-35))])]),
        "crumpled" => case(10; shapes = crumpled.(2:5)),
        "crumpled, more" => case(10; shapes = crumpled.(6:9)),
        "cockled" => case(10; shapes = [Shape(waves = (0.003, λ)) for λ in (0.030, 0.037, 0.043, 0.051)]),
        "curled toward face" => case(10; shapes = [Shape(curl = 0.3)]),
        "curled away" => case(10; shapes = [Shape(curl = -0.3)]),
        "folded on flat" => case(4; shapes = [flat, flat, flat, letter_fold(deg2rad(-40); hinge = 0.05)]),
        "crumpled under flat" => case(4; shapes = [flat, flat, crumpled(5), flat]),
    ]
end

"""
    limits()

Cases just past what `envelope` covers, to find where the feeder stops working: one feed each.
"""
limits() = [
    "letter fold -60°" => case(10; sheets = 2, shapes = [letter_fold(deg2rad(-60))]),
    "letter fold -50°, soft" => case(10; sheets = 2, shapes = [letter_fold(deg2rad(-50); hinge = 0.05)]),
    "half fold -40°" => case(10; sheets = 2, shapes = [half_fold(deg2rad(-40))]),
    "crumpled 1: 60° valley over its last 130 mm" => case(10; sheets = 2, shapes = [Shape(), crumpled(1)]),
    "curled toward face, 150 mm" => case(10; sheets = 2, shapes = [Shape(curl = 0.15)]),
    "curled away, 150 mm" => case(10; sheets = 2, shapes = [Shape(curl = -0.15)]),
    "creased head -40°" => case(10; sheets = 2, shapes = [Shape(creases = [(0.015, deg2rad(-40))])]),
]

"""
    run_case(design, settings; fps = 4, max_time)

Runs one case; returns the simulation and its frames. `max_time` defaults to the time the
cycles should take, with room for a slow feed.
"""
function run_case(d::FeederDesign, s::FeedSettings; fps = 4, max_time = s.settle + s.cycles * (s.eject_travel / s.speed + s.rest) * 1.3)
    sim = FeederSim(d, s)
    frames = run!(sim; fps, max_time)
    return sim, frames
end

passed(c::Cycle) = c.outcome == :landed
passed(sim::FeederSim) = length(sim.controller.cycles) == sim.settings.cycles && all(passed, sim.controller.cycles)

"""
    sweep(design, cases)

Runs the cases on all threads; returns name => (simulation, frames) for each.
"""
function sweep(d::FeederDesign, cases = envelope())
    tasks = [Threads.@spawn(name => run_case(d, s)) for (name, s) in cases]
    return fetch.(tasks)
end

"One line per case: passed or not, and per cycle its outcome, sheets fed, height and relief in the box, the next sheet's lead and the motors' peak forces."
function sweep_report(io::IO, results)
    for (name, (sim, _)) in results
        cycles = [(c.outcome, length(c.fed), round(c.height; digits = 1), round(c.relief; digits = 1), round(c.next_lead; digits = 1),
            [k => round(v; digits = 2) for (k, v) in c.peak]) for c in sim.controller.cycles]
        println(io, rpad(name, 26), passed(sim) ? "ok   " : "FAIL ", join(cycles, "  "))
    end
end

"""
    pick_test(design, settings; time = 8.0)

Only the start of the first feed: runs `time` seconds and returns how far the heads of the top
sheet and of the one under it got past the nip (mm, along the nip) and the drive motor's peak
force (N).
"""
function pick_test(d::FeederDesign, s::FeedSettings; time = 8.0)
    sim = FeederSim(d, s)
    run!(sim; fps = 2, max_time = time)
    lead(k) = dot(sheet_points(sim, k)[1] - sim.nip, sim.down) * 1.0e3
    n = s.sheets
    peak = get(last(sim.controller.cycles).peak, sim.pick.name, NaN)
    return (top = round(lead(n); digits = 1), next = n > 1 ? round(lead(n - 1); digits = 1) : NaN, force = round(peak; digits = 2))
end

"A pick test passes when the top sheet is well into the nip and the next one has not reached it."
picked(r) = r.top > 20.0 && !(r.next > -0.5)
