"""
    Paperhawk

A hands-free document scanner: a phone mounted above the desk films it, and
every sheet put down and left still is captured. Frames come from the phone's
camera over adb, the sheet in a frame is found and its corners measured to a
fraction of a pixel, and it is warped flat onto A4. Each page is cleaned
(light evened out, paper white), turned upright and read, and lands in an
editable draft. Once reviewed, the draft becomes numbered, searchable PDFs in
a document archive, summarised by a local LLM.

All image processing runs on the GPU, through Mantle: finding the sheet
([`PageDetector`](@ref)), warping and cleaning the page ([`process_page`](@ref)),
and reading it with PP-OCRv6 through JuliaVision's `PPOCRRunner`. Curved pages
can be straightened with UVDoc first.

Images are `img[x, y]`, x first, the way frames come out of the decoder; only
files on disk have rows first.

    using Paperhawk
    scanner()                       # the window; returns when it is closed
    scanner(; select = "RTX 4000")  # on a particular GPU

See `docs/gui.md` for the scanner and `docs/archive.md` for the archive.
"""
module Paperhawk

using LinearAlgebra
using Sockets
using Dates
using JSON3, SHA, TOML
import SQLite, DBInterface
import FileWatching.Pidfile
using ImageCore
using PNGFiles, JpegTurbo, CodecZlib
using FFMPEG_jll
using GeometryBasics: Vec, Vec2f, Vec3, Mat, Mat3f
import Mantle, PPOCRRunner, UVDocRunner, BonsaiRunner
import GPUFiltering as GF
import KernelAbstractions as KA
using KernelAbstractions: @kernel, @index, @Const

"""
    data_dir(parts...) -> String

Where drafts and the archive live unless told otherwise: `~/Documents/Paperhawk`,
outside the repository, since they hold private documents.
"""
data_dir(parts...) = joinpath(homedir(), "Documents", "Paperhawk", parts...)

export Camera, PhoneCamera, frame, frame!
export Page, PageDetector, Detection, detect!, find_page, paper_size
export Trigger, update!, beep
export Word, PaddleOCR, orientation, read_words, process_page
export PDFPage, write_pdf
export DocumentArchive, BonsaiClassifier
export archive_document!, document_record, search_documents, update_document!, retry_classification!, wait_archive
export ReviewSession, scanner, scanner_gui, review_add!, review_edit!, review_move!, review_delete!, review_undo!
export review_groups, review_issues, review_commit!, review_wait
public data_dir, anygpu, Previews

include("gpu.jl")
include("camera.jl")
include("detect.jl")
include("warp.jl")
include("trigger.jl")
include("page.jl")
include("ocr.jl")
include("preview.jl")
include("pdf.jl")
include("classify.jl")
include("database.jl")
include("archive.jl")
include("draftpng.jl")
include("review.jl")

"""The scanner window, see [`GUI`](@ref)."""
function scanner_gui end
"""Open the scanner and wait until its window is closed, see [`GUI`](@ref)."""
function scanner end
include("gui.jl")


end
