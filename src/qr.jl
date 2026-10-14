# QR codes: reading them with zbar, and making the separator sheet's own.
#
# No QR encoder in the registry works with the current image packages, and a
# separator needs only a short text, so this is a small one: byte mode, error
# correction level M, versions 1 to 3 (a single Reed-Solomon block), following
# ISO/IEC 18004. zbar reads what it makes, which the tests check.

const SEPARATOR_TEXT = "ASCANNER:SEPARATOR"

function numbered_separator(codes)
    numbers = Int[]
    for code in codes
        m = match(r"^ASCANNER:DOC:([0-9]{6,12})$",code)
        m === nothing && continue
        n = parse(Int,m[1])
        n > 0 || throw(ArgumentError("invalid document number on cover sheet"))
        push!(numbers,n)
    end
    unique!(numbers)
    length(numbers) <= 1 || throw(ArgumentError("multiple document numbers on one cover sheet"))
    return isempty(numbers) ? nothing : only(numbers)
end

# GF(256) with the QR polynomial x^8 + x^4 + x^3 + x^2 + 1.
const GF_EXP, GF_LOG = let
    exp, log = zeros(UInt8, 512), zeros(Int, 256)
    x = 1
    for i in 0:254
        exp[i + 1] = x
        log[x + 1] = i
        x <<= 1
        x > 255 && (x ⊻= 0x11d)
    end
    for i in 255:511
        exp[i + 1] = exp[i - 254]
    end
    exp, log
end

gf_mul(a::UInt8, b::UInt8) = (a == 0 || b == 0) ? 0x00 : GF_EXP[GF_LOG[a + 1] + GF_LOG[b + 1] + 1]

"""
    reed_solomon(data, n) -> Vector{UInt8}

The `n` error correction codewords for `data`.
"""
function reed_solomon(data::AbstractVector{UInt8}, n::Int)
    # Generator polynomial ∏ (x - αⁱ), highest power first.
    gen = UInt8[1]
    for i in 0:(n - 1)
        next = zeros(UInt8, length(gen) + 1)
        for (j, c) in enumerate(gen)
            next[j] ⊻= c
            next[j + 1] ⊻= gf_mul(c, GF_EXP[i + 1])
        end
        gen = next
    end
    rem = zeros(UInt8, n)
    for b in data
        factor = b ⊻ rem[1]
        rem = [rem[2:end]; 0x00]
        factor == 0 && continue
        for j in 1:n
            rem[j] ⊻= gf_mul(gen[j + 1], factor)
        end
    end
    return rem
end

# Level M, single block: (data codewords, error correction codewords) per version.
const QR_M_BLOCKS = ((16, 10), (28, 16), (44, 26))

"""
    qr_matrix(text) -> BitMatrix

The QR code for `text` (at most 42 bytes), `true` for dark modules, indexed
`[row, column]` without the quiet zone.
"""
function qr_matrix(text::AbstractString)
    bytes = Vector{UInt8}(codeunits(text))
    version = findfirst(((d, _),) -> 4 + 8 + 8length(bytes) <= 8d, QR_M_BLOCKS)
    version === nothing && throw(ArgumentError("text too long for a version 1-3 QR code: $(length(bytes)) bytes"))
    ndata, necc = QR_M_BLOCKS[version]
    # Byte mode, count, data, terminator, then pad bytes.
    bits = Bool[]
    push_bits!(v, n) = append!(bits, ((v >> i) & 1 == 1 for i in (n - 1):-1:0))
    push_bits!(0b0100, 4)
    push_bits!(length(bytes), 8)
    foreach(b -> push_bits!(b, 8), bytes)
    push_bits!(0, min(4, 8ndata - length(bits)))
    push_bits!(0, mod(-length(bits), 8))
    data = [UInt8(foldl((a, b) -> 2a + b, bits[i:(i + 7)]; init = 0)) for i in 1:8:length(bits)]
    pad = (0xec, 0x11)
    while length(data) < ndata
        push!(data, pad[isodd(length(data) - length(bits) ÷ 8) + 1])
    end
    codewords = [data; reed_solomon(data, necc)]

    n = 17 + 4version
    dark = falses(n, n)
    func = falses(n, n)
    setf(r, c, v) = (dark[r + 1, c + 1] = v; func[r + 1, c + 1] = true)
    # Finder patterns with their white separators.
    for (r0, c0) in ((0, 0), (0, n - 7), (n - 7, 0)), dr in -1:7, dc in -1:7
        r, c = r0 + dr, c0 + dc
        (0 <= r < n && 0 <= c < n) || continue
        d = max(abs(dr - 3), abs(dc - 3))
        setf(r, c, d != 2 && d != 4)
    end
    # Timing patterns.
    for i in 8:(n - 9)
        setf(6, i, iseven(i))
        setf(i, 6, iseven(i))
    end
    # The alignment pattern, from version 2 on.
    if version >= 2
        p = 4version + 10
        for dr in -2:2, dc in -2:2
            setf(p + dr, p + dc, max(abs(dr), abs(dc)) != 1)
        end
    end
    # Reserve the format areas; they are written once the mask is chosen.
    for i in 0:8
        func[9, i + 1] = func[i + 1, 9] = true
    end
    for i in 0:7
        func[9, n - i] = func[n - i, 9] = true
    end
    setf(n - 8, 8, true)
    # Codewords, two columns at a time in a zigzag from the bottom right.
    i = 0
    right = n - 1
    while right >= 1
        right == 6 && (right = 5)
        upward = ((right + 1) & 2) == 0
        for vert in 0:(n - 1), j in 0:1
            c = right - j
            r = upward ? n - 1 - vert : vert
            if !func[r + 1, c + 1] && i < 8length(codewords)
                dark[r + 1, c + 1] = (codewords[i >> 3 + 1] >> (7 - (i & 7))) & 1 == 1
                i += 1
            end
        end
        right -= 2
    end
    best = argmin(m -> penalty(apply_mask(dark, func, m)), 0:7)
    out = apply_mask(dark, func, best)
    draw_format!(out, best)
    return out
end

const QR_MASKS = (
    (r, c) -> iseven(r + c), (r, c) -> iseven(r), (r, c) -> c % 3 == 0, (r, c) -> (r + c) % 3 == 0,
    (r, c) -> iseven(r ÷ 2 + c ÷ 3), (r, c) -> (r * c) % 2 + (r * c) % 3 == 0,
    (r, c) -> iseven((r * c) % 2 + (r * c) % 3), (r, c) -> iseven((r + c) % 2 + (r * c) % 3),
)

function apply_mask(dark::BitMatrix, func::BitMatrix, m::Int)
    out = copy(dark)
    n = size(dark, 1)
    for r in 0:(n - 1), c in 0:(n - 1)
        func[r + 1, c + 1] || (out[r + 1, c + 1] ⊻= QR_MASKS[m + 1](r, c))
    end
    draw_format!(out, m)
    return out
end

# Level M (format bits 00) and the mask, BCH-protected, written twice.
function draw_format!(m::BitMatrix, mask::Int)
    n = size(m, 1)
    data = mask
    rem = data
    for _ in 1:10
        rem = (rem << 1) ⊻ ((rem >> 9) * 0x537)
    end
    bits = ((data << 10) | rem) ⊻ 0x5412
    bit(i) = (bits >> i) & 1 == 1
    set(c, r, v) = (m[r + 1, c + 1] = v)
    for i in 0:5
        set(8, i, bit(i))
    end
    set(8, 7, bit(6)); set(8, 8, bit(7)); set(7, 8, bit(8))
    for i in 9:14
        set(14 - i, 8, bit(i))
    end
    for i in 0:7
        set(n - 1 - i, 8, bit(i))
    end
    for i in 8:14
        set(8, n - 15 + i, bit(i))
    end
    set(8, n - 8, true)
    return m
end

# The standard's penalty for runs, blocks, finder look-alikes and imbalance.
function penalty(m::BitMatrix)
    n = size(m, 1)
    p = 0
    for lines in (eachrow(m), eachcol(m)), line in lines
        run = 1
        for k in 2:n
            if line[k] == line[k - 1]
                run += 1
            else
                run >= 5 && (p += run - 2)
                run = 1
            end
        end
        run >= 5 && (p += run - 2)
        s = String(map(b -> b ? '1' : '0', line))
        p += 40 * (count("1011101" * "0000", s) + count("0000" * "1011101", s))
    end
    for r in 1:(n - 1), c in 1:(n - 1)
        m[r, c] == m[r + 1, c] == m[r, c + 1] == m[r + 1, c + 1] && (p += 3)
    end
    p += 10 * (abs(round(Int, 100 * count(m) / n^2) - 50) ÷ 5)
    return p
end

"""
    qr_image(text; module_size = 10, quiet = 4) -> Matrix{Gray{Bool}}

The QR code for `text` as an image `img[x, y]`, white around it.
"""
function qr_image(text::AbstractString; module_size::Int = 10, quiet::Int = 4)
    m = qr_matrix(text)
    n = size(m, 1) + 2quiet
    img = fill(Gray(true), n * module_size, n * module_size)
    for r in 1:size(m, 1), c in 1:size(m, 2)
        m[r, c] || continue
        xs = ((c - 1 + quiet) * module_size + 1):((c + quiet) * module_size)
        ys = ((r - 1 + quiet) * module_size + 1):((r + quiet) * module_size)
        img[xs, ys] .= Gray(false)
    end
    return img
end

"""
    with_image_file(f, img; format = "png")

Calls `f(path)` with `img[x, y]` written to a temporary file.
"""
function with_image_file(f, img::AbstractMatrix; format::String = "png")
    path = tempname() * "." * format
    try
        save(path, permutedims(img))
        return f(path)
    finally
        rm(path; force = true)
    end
end

"""
    qr_codes(img; width = 1240) -> Vector{String}

The texts of the QR codes zbar finds in `img[x, y]`. zbar gets every f-th
pixel in grey, about `width` across, which is plenty for a code a few
centimetres wide.
"""
function qr_codes(img::AbstractMatrix; width::Int = 1240)
    f = max(1, size(img, 1) ÷ width)
    small = [Gray{N0f8}(clamp(luminance(img[x, y]), 0, 1)) for x in 1:f:size(img, 1), y in 1:f:size(img, 2)]
    out = with_image_file(small) do path
        read(pipeline(ignorestatus(`$(zbar_jll.zbarimg()) --quiet --raw -Sdisable -Sqrcode.enable $path`); stderr = devnull), String)
    end
    return filter(!isempty, split(out, '\n'))
end

"""
    isseparator(img) -> Bool

Whether `img[x, y]` is a separator sheet: a page with the separator's QR code.
"""
function isseparator(img::AbstractMatrix)
    codes = qr_codes(img)
    return SEPARATOR_TEXT in codes || numbered_separator(codes) !== nothing
end
