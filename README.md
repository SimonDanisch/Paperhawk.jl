# Paperhawk

A hands-free document scanner. A phone mounted above the desk films it; every
sheet you put down and leave still is captured, cleaned, turned upright and
read. You review the pages in a native window, fix what needs fixing, and
archive them as numbered, searchable PDFs, summarised by a local LLM. All image
processing and all models run on your GPU; nothing leaves the machine.

The interface is in German.

## What you need

- **Julia 1.12** on Linux, Windows or macOS.
- **A GPU.** Everything runs through
  [Mantle](https://github.com/SimonDanisch/Mantle.jl), which runs the same
  Julia kernels on any GPU: Vulkan on Linux and Windows (NVIDIA, AMD, Intel),
  Metal on Apple silicon. Paperhawk takes the best device it finds; `--gpu`
  picks another. Reading pages takes about 2 GB of GPU memory, the optional
  summaries about 6 GB more.
- **An Android phone** with USB debugging on, and `adb` installed. Nothing is
  installed on the phone: Paperhawk streams its camera through the scrcpy
  server (`assets/scrcpy-server`). The default camera size, 4624×3472, is the
  Xiaomi Mi 10T's; other phones may need another one (`PhoneCamera(; size)`).

## Install

The GPU stack is not registered yet. Paperhawk is developed in a working folder
that holds one Julia environment and, under `dev/`, Paperhawk and the stack's
repositories side by side:

| `dev/`               | Repository                                                                                  | Branch                |
|----------------------|---------------------------------------------------------------------------------------------|-----------------------|
| `Paperhawk`          | [SimonDanisch/Paperhawk.jl](https://github.com/SimonDanisch/Paperhawk.jl)                   | `main`                |
| `JuliaVision`        | [SimonDanisch/JuliaVision](https://github.com/SimonDanisch/JuliaVision)                     | `sd/mantle-dev`       |
| `Mantle`             | [SimonDanisch/Mantle.jl](https://github.com/SimonDanisch/Mantle.jl)                         | `sd/lava-refactor`    |
| `Lava`               | [SimonDanisch/Lava.jl](https://github.com/SimonDanisch/Lava.jl)                             | `sd/lava-refactor`    |
| `KernelAbstractions` | [SimonDanisch/KernelAbstractions.jl](https://github.com/SimonDanisch/KernelAbstractions.jl) | `sd/lava-refactor`    |
| `Metal`              | [SimonDanisch/Metal.jl](https://github.com/SimonDanisch/Metal.jl)                           | `sd/lava-refactor`    |
| `GPUArrays`          | [JuliaGPU/GPUArrays.jl](https://github.com/JuliaGPU/GPUArrays.jl)                           | `main`                |
| `Vulkan`             | [JuliaGPU/Vulkan.jl](https://github.com/JuliaGPU/Vulkan.jl)                                 | `sd/vk1.4`            |
| `VulkanCore`         | [JuliaGPU/VulkanCore.jl](https://github.com/JuliaGPU/VulkanCore.jl)                         | `sd/vk1.4`            |
| `CompilerCaching`    | [SimonDanisch/CompilerCaching.jl](https://github.com/SimonDanisch/CompilerCaching.jl)       | `sd/published-invoke` |
| `Raycore`            | [JuliaGeometry/Raycore.jl](https://github.com/JuliaGeometry/Raycore.jl)                     | `sd/with-texture`     |
| `PrintSim`           | [SimonDanisch/PrintSim.jl](https://github.com/SimonDanisch/PrintSim.jl)                     | `main`                |

The environment's `Project.toml` lists them in `[sources]` with
`path = "dev/<name>"` (the runners as `dev/JuliaVision/<runner>`), and Makie,
GLMakie, RayMakie and ComputePipeline with `rev = "sd/lava-refactor"` from
[Makie.jl](https://github.com/MakieOrg/Makie.jl). PrintSim and RayMakie are
only needed for the [sheet feeder](hardware/feeder).

The model weights download on first use.

## Run

```sh
julia --project=. dev/Paperhawk/tools/scanner.jl                    # the best GPU
julia --project=. dev/Paperhawk/tools/scanner.jl --gpu "RTX 4000"   # a particular one
julia --project=. dev/Paperhawk/tools/scanner.jl --classify         # with LLM summaries
```

All commands run in the working folder. Drafts and the archive live in
`~/Documents/Paperhawk`, outside the repository. See [docs/gui.md](docs/gui.md)
for the scanner and [docs/archive.md](docs/archive.md) for the archive (both in
German).

## How it works

- **Finding the sheet:** whiteness, Otsu and connected components on the GPU,
  then the edges measured along their profiles to a fraction of a pixel.
- **The page:** warped flat onto A4, optionally straightened by
  [UVDoc](https://github.com/tanguymagne/UVDoc), lighting evened out, paper
  made white, checked for being blank.
- **Reading:** PP-OCRv6 through
  [JuliaVision](https://github.com/SimonDanisch/JuliaVision)'s `PPOCRRunner`,
  on the same device: which way up the page is, its lines and its words.
- **Archiving:** numbered PDFs with a text layer, a SQLite full-text index, and
  a summary by Ternary-Bonsai-2 27B through `BonsaiRunner`.

GPU work is written in Julia with KernelAbstractions and runs through
[Mantle](https://github.com/SimonDanisch/Mantle.jl) on Vulkan or Metal. The image operations are
JuliaVision's `GPUFiltering`; Paperhawk keeps only the page's own kernels.

## Tests

```sh
julia --project=. -e 'using Pkg; Pkg.test("Paperhawk")'
```

The tests need the GPU and a display (GLMakie opens windows).
