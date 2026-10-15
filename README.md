# Paperhawk

A hands-free document scanner. A phone mounted above the desk films it; every
sheet you put down and leave still is captured, cleaned, turned upright and
read. You review the pages in a native window, fix what needs fixing, and
archive them as numbered, searchable PDFs, summarised by a local LLM. All image
processing and all models run on your GPU; nothing leaves the machine.

The interface is in German.

## What you need

- **Linux** with Julia 1.12. Only Linux is tested.
- **A GPU with Vulkan**, Float16 and Int8 shader support: a recent NVIDIA or
  AMD card. Reading pages takes about 2 GB of GPU memory; the optional
  summaries take about 6 GB more.
- **An Android phone** with USB debugging on, and `adb` installed. Nothing is
  installed on the phone: Paperhawk streams its camera through the scrcpy
  server (`assets/scrcpy-server`). The default camera size, 4624×3472, is the
  Xiaomi Mi 10T's; other phones may need another one (`PhoneCamera(; size)`).

## Install

The GPU stack is not registered yet, so it comes along as submodules:

```sh
git clone --recursive https://github.com/SimonDanisch/Paperhawk.jl
cd Paperhawk.jl
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

The model weights download on first use.

## Run

```sh
julia --project=. tools/scanner.jl                    # the best GPU
julia --project=. tools/scanner.jl --gpu "RTX 4000"   # a particular one
julia --project=. tools/scanner.jl --classify         # with LLM summaries
```

Drafts and the archive live in `~/Documents/Paperhawk`, outside the
repository. See [docs/gui.md](docs/gui.md) for the scanner and
[docs/archive.md](docs/archive.md) for the archive (both in German).

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

GPU work runs through [Mantle](https://github.com/SimonDanisch/Mantle.jl) on
Vulkan, written in Julia with KernelAbstractions.

## Tests

```sh
julia --project=. -e 'using Pkg; Pkg.test()'
```

The tests need the GPU and a display (GLMakie opens windows).
