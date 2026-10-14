# Scanning hands-free: put a sheet down, hear the beep, take it away.
#
# A sheet that has lain still for `hold` seconds is captured, once. The next
# capture needs different content: the next sheet or the back side. The same
# sheet lying there, briefly covered by a hand, or lost by the detector for a
# few frames is never captured again. Deliberate rescans use a manual capture.

"""
    Trigger(; hold = 0.5, tolerance = 0.004, clear = 3, same_content = 0.06)

The state of the hands-free trigger, fed one detection per frame with
[`update!`](@ref).

  - `hold`: seconds the corners and image content must stay still before capture.
  - `tolerance`: how far a corner may move from one frame to the next and
    still count as lying still, as a fraction of the sheet's diagonal. The
    detector's corner jitter grows with the camera resolution.
  - `clear`: frames in a row without a sheet that count as the sheet being gone.
  - `same_content`: the mean difference of two small grey thumbnails below
    which a sheet counts as the one already captured. Content is checked even
    if the corners do not move, so aligned sheets can be stacked continuously.
"""
mutable struct Trigger
    hold::Float64
    tolerance::Float32
    clear::Int
    same_content::Float32
    state::Symbol             # :empty, :settling, :captured
    since::Float64            # when the sheet last moved
    last::Union{Page, Nothing}
    gone::Int                 # frames in a row without a sheet
    captured::Union{Matrix{Float32}, Nothing}  # thumbnail of the last capture
    settling_content::Union{Matrix{Float32}, Nothing} # reference for the stable interval
end

Trigger(; hold = 0.5, tolerance = 0.004, clear = 3, same_content = 0.06) =
    Trigger(hold, tolerance, clear, same_content, :empty, 0.0, nothing, 0, nothing, nothing)

movement(a::Page, b::Page) = maximum(norm.(a.corners .- b.corners))
diagonal(page::Page) = max(norm(page.corners[3] - page.corners[1]), norm(page.corners[4] - page.corners[2]))

content_difference(a::Matrix{Float32}, b::Matrix{Float32}) = sum(abs, a .- b) / length(a) / 2

"""
    update!(trigger, detection::Detection, now) -> Bool
    update!(trigger, page, now; thumbnail = nothing) -> Bool

One frame's detection, `page` or `nothing`, seen at time `now` in seconds.
True when this frame is the one to capture. `thumbnail` is the sheet's
[`thumbnail`](@ref), used to detect new content and wait for it to settle,
including when the corners stay fixed.
"""
update!(t::Trigger, d::Detection, now::Real) = update!(t, d.page, now; d.thumbnail)

function update!(t::Trigger, page::Union{Page, Nothing}, now::Real; thumbnail::Union{Matrix{Float32}, Nothing} = nothing)
    if page === nothing
        t.gone += 1
        # A brief occlusion must not count as time spent lying still.
        t.since = now
        t.settling_content = nothing
        if t.gone >= t.clear
            t.state = :empty
            t.last = nothing
        end
        return false
    end
    t.gone = 0
    moved = t.last === nothing || movement(page, t.last) > t.tolerance * diagonal(page)
    t.last = page
    thumb = thumbnail
    if t.state === :empty
        t.state, t.since = :settling, now
        t.settling_content = thumb
        return false
    elseif t.state === :captured
        changed = thumb !== nothing && t.captured !== nothing &&
            content_difference(thumb, t.captured) >= t.same_content
        # A new sheet can cover the old one with exactly the same corners.
        (moved || changed) || return false
        t.state, t.since = :settling, now
        t.settling_content = thumb
        return false
    end
    # :settling
    changed = thumb !== nothing && t.settling_content !== nothing &&
        content_difference(thumb, t.settling_content) >= t.same_content
    if moved || changed || (thumb !== nothing && t.settling_content === nothing)
        t.since = now
        t.settling_content = thumb
        return false
    end
    now - t.since < t.hold && return false
    t.state = :captured
    duplicate = thumb !== nothing && t.captured !== nothing &&
        content_difference(thumb, t.captured) < t.same_content
    t.settling_content = nothing
    duplicate && return false
    t.captured = thumb
    return true
end

"""
    beep(times = 1; frequency = 1200, duration = 0.12, volume = 0.4)

`times` short tones through ALSA's `aplay`, without waiting for them to finish.
"""
function beep(times::Int = 1; frequency = 1200, duration = 0.12, volume = 0.4, rate = 44100, gap = 0.08)
    n = round(Int, duration * rate)
    silence = round(Int, gap * rate)
    # A short fade in and out keeps the speaker from clicking.
    fade(i) = min(1.0, i / 200, (n - i) / 200)
    tone = [round(Int16, 32767 * volume * fade(i) * sin(2π * frequency * i / rate)) for i in 0:(n - 1)]
    samples = reduce(vcat, (k == 1 ? tone : [zeros(Int16, silence); tone] for k in 1:times))
    m = length(samples)
    io = IOBuffer()
    write(io, "RIFF", UInt32(36 + 2m), "WAVE", "fmt ", UInt32(16), UInt16(1), UInt16(1), UInt32(rate), UInt32(2rate), UInt16(2), UInt16(16), "data", UInt32(2m))
    write(io, htol.(samples))
    try
        run(pipeline(`aplay -q -`; stdin = IOBuffer(take!(io)), stderr = devnull); wait = false)
    catch
        print(stdout, '\a'^times)
    end
    return nothing
end
