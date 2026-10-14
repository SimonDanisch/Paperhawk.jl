"""
    Paperhawk

A document scanner for a phone mounted above a dark desk. Frames come from the
phone's camera over adb, the sheet in a frame is found and its corners measured
to a fraction of a pixel, and it is warped flat onto A4. Each page is cleaned
(light evened out, paper white), turned upright and read, and the pages become
searchable PDFs: one per document, split at separator sheets, in duplex order
when asked.

All image processing runs on the GPU, through Mantle: finding the sheet
([`PageDetector`](@ref)), warping and cleaning the page, and reading it with
PP-OCRv6 through JuliaVision's `PPOCRRunner` (lines, text, and which way up a
page is). For curved pages, pass `dewarper = uvdoc(ocr)` to `start` or
`make_pdfs` to apply UVDoc before cleaning and OCR.

For paper storage in scan order, open `DocumentArchive("archive"; classifier =
BonsaiClassifier())` and pass `archive` to `start`. Documents are numbered
automatically from 1 onward. PDFs keep their numbers; the local LLM supplies searchable
metadata in the background. See `docs/archive.md` for the complete workflow.

Images are `img[x, y]`, x first, the way frames come out of the decoder; only
files on disk have rows first.

    using Paperhawk
    separator_sheet("separator.pdf")   # print it; put one between documents

    cam = PhoneCamera()                # back camera, 4624x3472, over adb
    ocr = PaddleOCR()
    scanner = start(cam; ocr)          # put a sheet down, beep, take it away
    pdfs = stop!(scanner)              # scans/<date_time>/<name>_01.pdf, …
    close(cam)

    scanner = start(cam; ocr, duplex = true, mode = :bw)   # fronts, turn the stack, backs
    make_pdfs("scans/<date_time>"; ocr, mode = :gray)      # the same pages again
"""
module Paperhawk

using LinearAlgebra
using Sockets
using Dates
using Downloads
import Distributed
using JSON3, SHA, TOML
import SQLite, DBInterface
import FileWatching.Pidfile
using FileIO, ImageCore
using PNGFiles, JpegTurbo, CodecZlib
using FFMPEG_jll, zbar_jll
using GeometryBasics: Vec, Vec2f, Vec3, Mat
import Mantle, PPOCRRunner, UVDocRunner, BonsaiRunner
import KernelAbstractions as KA
using KernelAbstractions: @kernel, @index, @Const

include("camera.jl")
include("detect.jl")
include("warp.jl")
include("trigger.jl")
include("ocr.jl")
include("gpu.jl")
include("gpuimages.jl")
include("preview.jl")
include("qr.jl")
include("pdf.jl")
include("classify.jl")
include("database.jl")
include("archive.jl")
include("document.jl")
include("scanner.jl")
include("draftpng.jl")
include("review.jl")
include("processing.jl")

"""Native Makie scanner interface. Load GLMakie before calling `scanner_gui`."""
function scanner_gui end

export Camera, PhoneCamera, frame, frame!
export Page, PageDetector, Detection, detect!, find_page, paper_size
export Trigger, update!, beep, Scanner, start, stop!
export orientation, Word, read_words
export OCREngine, PaddleOCR, default_ocr
export qr_codes, isseparator, separator_sheet
export PDFPage, write_pdf, process_page, make_pdfs
export uvdoc, unwarp
export DocumentArchive, BonsaiClassifier, reserve_numbers!, number_sheets
export archive_document!, document_record, search_documents, update_document!, retry_classification!, wait_archive
export ReviewSession, scanner_gui, review_add!, review_edit!, review_move!, review_delete!, review_undo!
export review_groups, review_issues, review_commit!, review_wait
export close_processing!

end
