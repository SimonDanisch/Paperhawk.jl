# The assembly pictures, raytraced with RayMakie: the parts in the materials they are made of, on
# a plywood desk in a bright photo studio (a Poly Haven HDRI, CC0), lit by its window light, the
# room behind slightly out of focus. In each step its own parts are in full color, parts built
# in before are paler. From the repository root, with this directory's environment active:
#
#     include("hardware/feeder/PaperFeeder.jl"); using .PaperFeeder
#     include("hardware/feeder/raytrace/guide.jl")
#     studio = Studio()
#     assembly_guide(studio, "hardware/feeder/assembly")
#     machine_picture(studio, "hardware/feeder/assembly/feeder.jpg")

using LinearAlgebra
using Downloads
using GeometryBasics
using RayMakie, Hikari
import .PaperFeeder: AssemblyStep, Part, FeederDesign, Build, Layout, Profile, parts, assembly_steps, cable_routes, step_scene,
    step_items, assembled, framing, tube, sample_points, stack_mesh, write_assembly_markdown

"Downloads a Poly Haven asset (CC0) into the cache the first time; returns its local path."
function polyhaven(url; dir = joinpath(homedir(), ".cache", "paperhawk-feeder", "polyhaven"))
    path = joinpath(dir, basename(url))
    isfile(path) || Downloads.download(url, joinpath(mkpath(dir), basename(url)))
    return path
end

"Linear reflectance of an sRGB color channel; Hikari's reflectances are linear."
linear(x) = x <= 0.04045f0 ? x / 12.92f0 : ((x + 0.055f0) / 1.055f0)^2.4f0

"Printed plastic of sRGB color `c`, kept below 85 % reflectance like real filament."
plastic(c, roughness) = Hikari.CoatedDiffuse(reflectance = 0.85f0 .* linear.((c.r, c.g, c.b)), roughness = Float32(roughness))

"The bought and household parts, by name: NBR O-rings, the motors' steel cans, solder-masked boards, cork, paper."
bought_materials() = [
    r"_orings$" => Hikari.CoatedDiffuse(reflectance = (0.03f0, 0.03f0, 0.03f0), roughness = 0.6f0),
    r"_motor$" => Hikari.Conductor(eta = (1.6f0, 1.6f0, 1.52f0), k = (1.6f0, 1.6f0, 1.52f0), roughness = 0.15f0),
    r"^uln2003_(drive|exit)$" => Hikari.CoatedDiffuse(reflectance = (0.02f0, 0.16f0, 0.05f0), roughness = 0.15f0),
    r"^esp32$" => Hikari.CoatedDiffuse(reflectance = (0.02f0, 0.02f0, 0.025f0), roughness = 0.15f0),
    r"^cork_strip$" => Hikari.Diffuse(Kd = linear.((0.76f0, 0.6f0, 0.42f0))),
    r"^paper$" => Hikari.Diffuse(Kd = (0.8f0, 0.8f0, 0.78f0)),
]

"The direction toward pixel `(row, col)` of an equirectangular map (Hikari's layout: +y up, row 1 the zenith)."
function direction(sky::AbstractMatrix, row, col)
    h, w = size(sky)
    θ = (row - 0.5f0) / h * Float32(π)
    φ = (col - 0.5f0) / w * 2.0f0 * Float32(π) - Float32(π)
    return Vec3f(sin(θ) * cos(φ), cos(θ), sin(θ) * sin(φ))
end

"The equirectangular map's radiance toward `d`."
function radiance(sky::AbstractMatrix, d)
    h, w = size(sky)
    θ = acos(clamp(d[2], -1.0f0, 1.0f0))
    φ = atan(d[3], d[1])
    col = clamp(floor(Int, (φ + Float32(π)) / (2.0f0 * Float32(π)) * w) + 1, 1, w)
    row = clamp(floor(Int, θ / Float32(π) * h) + 1, 1, h)
    return sky[row, col]
end

luminance(c) = 0.2126f0 * c.r + 0.7152f0 * c.g + 0.0722f0 * c.b

"Where the map's light comes from: the luminance-weighted direction of its brightest `share` of pixels."
function brightest(sky::AbstractMatrix; share = 0.002)
    h, w = size(sky)
    cut = partialsort(vec(luminance.(sky)), round(Int, (1 - share) * length(sky)))
    total = zero(Vec3f)
    for row in 1:h, col in 1:w
        L = luminance(sky[row, col])
        L > cut || continue
        total += L * sin((row - 0.5f0) / h * Float32(π)) * direction(sky, row, col)
    end
    return normalize(total)
end

"""
    Studio(; samples = 512, px_per_unit = 2, hdri, wood, exposure = 2, desk = (1600, 1000), aperture = 0.002, ...)

How the pictures are rendered. `samples` per pixel, `px_per_unit` pixels per figure unit.
`hdri` is an equirectangular environment (lighting, reflections and the room behind), turned
in every picture so its main light comes from above, behind and left of the camera, scaled by
`exposure`. The parts stand on a `desk` (mm) topped with the `wood` texture. The camera's lens
radius is `aperture` times its distance to the look-at point, for the same little depth of
field at every distance. `pla` and `petg` are the printed plastics' roughness. Parts built in
before move `fade_amount` of the way toward `fade` and turn matte (`matte`). `arrow` and `lead`
color the arrows and the motor leads.
"""
struct Studio
    samples::Int
    px_per_unit::Int
    sky::Matrix{RGBf}
    light::Vec3f
    exposure::Float32
    wood::Matrix{Hikari.RGBSpectrum}
    desk::Tuple{Float32, Float32}
    aperture::Float32
    pla::Float32
    petg::Float32
    fade::RGBf
    fade_amount::Float32
    matte::Float32
    arrow::RGBf
    lead::RGBf
    bought::Vector{Pair{Regex, Any}}
end

function Studio(; samples = 512, px_per_unit = 2,
        hdri = polyhaven("https://dl.polyhaven.org/file/ph-assets/HDRIs/exr/2k/brown_photostudio_02_2k.exr"),
        wood = polyhaven("https://dl.polyhaven.org/file/ph-assets/Textures/jpg/2k/plywood/plywood_diff_2k.jpg"),
        exposure = 2.0, desk = (1600, 1000), aperture = 0.002, pla = 0.45, petg = 0.12, fade = RGBf(0.86, 0.85, 0.83),
        fade_amount = 0.6, matte = 0.6, arrow = RGBf(0.85, 0.12, 0.08), lead = RGBf(0.12, 0.12, 0.14), bought = bought_materials())
    sky = RGBf.(Makie.FileIO.load(hdri))
    texture = map(c -> Hikari.RGBSpectrum(linear(Float32(c.r)), linear(Float32(c.g)), linear(Float32(c.b))), Makie.FileIO.load(wood))
    return Studio(samples, px_per_unit, sky, brightest(sky), exposure, texture, Float32.(desk), aperture, pla, petg, fade,
        fade_amount, matte, arrow, lead, bought)
end

"Part `q` in the material it is made of."
function material(st::Studio, q::Part)
    for (pattern, m) in st.bought
        occursin(pattern, q.name) && return m
    end
    return plastic(q.color, q.material == :PETG ? st.petg : st.pla)
end

"Part `q` when an earlier step built it in: its color faded and matte, so the step's own parts stand out."
function faded(st::Studio, q::Part)
    c, f, t = q.color, st.fade, st.fade_amount
    return plastic(RGBf(c.r + t * (f.r - c.r), c.g + t * (f.g - c.g), c.b + t * (f.b - c.b)), st.matte)
end

"Where the main light should come from: above, behind and left of the camera, so the faces it sees are lit."
function light_direction(s::AssemblyStep)
    view = normalize(s.lookat - s.eye)
    right = normalize(cross(view, s.up))
    up = normalize(cross(right, view))
    return normalize(-0.7f0 * view + up - 0.45f0 * right)
end

"The rotation from the map's frame into the scene: its +y onto `s.up`, its main light's azimuth onto `light_direction(s)`'s."
function sky_rotation(st::Studio, s::AssemblyStep)
    up = normalize(s.up)
    t = light_direction(s)
    to = normalize(t - dot(t, up) * up)
    from = normalize(Vec3f(st.light[1], 0, st.light[3]))
    y = Vec3f(0, 1, 0)
    return Mat3f(hcat(to, up, cross(to, up)) * transpose(hcat(from, y, cross(from, y))))
end

"""
    environment(st, s; n = 1024)

The light of a picture looking along step `s`'s direction: the HDRI turned by `sky_rotation`,
as the equal-area map Hikari samples (pixel `[i, j]` holds the direction at
`uv = ((j - ½) / n, (i - ½) / n)`).
"""
function environment(st::Studio, s::AssemblyStep; n = 1024)
    R = transpose(sky_rotation(st, s))
    image = Matrix{RGBf}(undef, n, n)
    Threads.@threads for i in 1:n
        for j in 1:n
            d = Hikari.equal_area_square_to_sphere(Point2f((j - 0.5f0) / n, (i - 0.5f0) / n))
            image[i, j] = st.exposure * radiance(st.sky, R * d)
        end
    end
    return Makie.EnvironmentLight(1.0f0, image)
end

"""
Points the camera of `ax` as the framed step `s` says, focused on its look-at point, and puts
the desk under everything `placed` (meshes with their offsets), its top at their lowest point.
"""
function camera_and_desk!(st::Studio, ax, s::AssemblyStep, placed; fov)
    cam = Makie.cam3d!(ax.scene; eyeposition = s.eye, s.lookat, upvector = s.up, fov, center = false)
    update_cam!(ax.scene, cam, s.eye, s.lookat, s.up)
    cam.focal_distance[] = norm(s.lookat - s.eye)
    cam.lens_radius[] = st.aperture * cam.focal_distance[]
    up = normalize(s.up)
    low = minimum(minimum(dot(Vec3f(q) + offset, up) for q in coordinates(m)) for (m, offset) in placed)
    x = Vec3f(1, 0, 0)
    a = abs(dot(x, up)) > 0.9f0 ? Vec3f(0, 0, 1) : normalize(x - dot(x, up) * up)
    b = cross(up, a)
    middle = Vec3f(0, -120, 60)
    c = middle + (low - dot(middle, up) - 0.2f0) * up
    w, d = st.desk ./ 2
    corners = [Point3f(c + i * w * a + j * d * b) for (i, j) in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
    uv = [Vec2f(0, 0), Vec2f(1, 0), Vec2f(1, 1), Vec2f(0, 1)]
    top = GeometryBasics.Mesh(corners, [GLTriangleFace(1, 2, 3), GLTriangleFace(1, 3, 4)]; normal = fill(up, 4), uv)
    mesh!(ax, top; material = Hikari.CoatedDiffuse(reflectance = Hikari.Texture(st.wood), roughness = 0.35f0))
    edges = vcat(corners .- Ref(0.5f0 * up), corners .- Ref(30.0f0 * up))
    mesh!(ax, normal_mesh(Rect3f(minimum(edges), maximum(edges) - minimum(edges))); material = Hikari.Diffuse(Kd = linear.((0.62f0, 0.5f0, 0.36f0))))
    return nothing
end

"Renders `fig` and writes it to `path` (JPEG): through the screen itself, since `save` does not hand `px_per_unit` on to RayMakie."
function save_picture(st::Studio, path, fig)
    Makie.update_state_before_display!(fig)
    screen = RayMakie.Screen(fig.scene; samples = st.samples)
    img = colorbuffer(screen; figure = fig, px_per_unit = st.px_per_unit)
    close(screen)
    save(path, img)
    return path
end

"""
    step_figure(st, k, s, scene; size, fov)

The picture of step `k` from its `step_scene`: the step's own parts in their materials, pulled
out along their way in with a red arrow each, earlier parts faded, the leads `s` names, framed
on what the step is about.
"""
function step_figure(st::Studio, k, s::AssemblyStep, scene; size, fov)
    fig = Figure(; size, backgroundcolor = :white)
    Label(fig[0, 1], "Step $k: $(s.title)"; fontsize = 30, halign = :left, tellwidth = false)
    ax = LScene(fig[1, 1]; show_axis = false, scenekw = (; lights = [environment(st, s)]))
    for (; part, offset, own) in scene.drawn
        translate!(mesh!(ax, part.mesh; material = own ? material(st, part) : faded(st, part)), offset)
    end
    isempty(scene.arrows) || mesh!(ax, merge(scene.arrows); material = plastic(st.arrow, 0.25f0))
    foreach(lead -> mesh!(ax, lead; material = plastic(st.lead, 0.25f0)), scene.leads)
    framed = framing(s, scene.focus, scene.context; fov, aspect = /(widths(viewport(ax.scene)[])...))
    camera_and_desk!(st, ax, framed, [(d.part.mesh, d.offset) for d in scene.drawn]; fov)
    return fig
end

"""
    assembly_guide(st, dir; design, build, ps, steps = all, size = (1400, 1050), fov = 32)

Renders one picture per assembly step into `dir` (`step_01.jpg`, …) and writes `ASSEMBLY.md`
next to it with the steps and their pictures. `steps` picks which pictures are rendered; the
Markdown always lists all of them.
"""
function assembly_guide(st::Studio, dir; design = FeederDesign(), build = Build(), ps = parts(design, build), steps = nothing,
        size = (1400, 1050), fov = 32)
    mkpath(dir)
    shown = assembled(ps)
    all_steps = assembly_steps(design, build)
    routes = cable_routes(design, build, Layout(design, build))
    done = Set{String}()
    images = String[]
    for (k, s) in enumerate(all_steps)
        path = joinpath(dir, "step_$(lpad(k, 2, '0')).jpg")
        push!(images, path)
        if isnothing(steps) || k in steps
            save_picture(st, path, step_figure(st, k, s, step_scene(s, shown, done, routes); size, fov))
        end
        s.kept && union!(done, step_items(s, shown))
    end
    write_assembly_markdown(joinpath(dirname(dir), "ASSEMBLY.md"), all_steps, images)
    return images
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
    foreach(q -> mesh!(ax, q.mesh; material = material(st, q)), vcat(shown, paper))
    for r in cable_routes(design, build, Layout(design, build))
        mesh!(ax, tube(r.points, 2.5); material = plastic(st.lead, 0.25f0))
    end
    focus = reduce(vcat, [sample_points(q.mesh) for q in shown])
    framed = framing(s, focus, Vec3f[]; fov, aspect = /(widths(viewport(ax.scene)[])...), fill = 0.9)
    camera_and_desk!(st, ax, framed, [(q.mesh, Vec3f(0)) for q in shown]; fov)
    return save_picture(st, path, fig)
end
