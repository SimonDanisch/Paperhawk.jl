# The phone's camera over adb, with nothing installed on the phone.
#
# scrcpy's server is a jar that runs on the phone through `app_process`, with
# the shell user's right to open the camera. It streams the camera as H.265
# through a local socket, which `adb forward` makes a TCP port here. ffmpeg
# decodes the stream to RGB, and a task keeps the newest frame.
#
# The server deletes its own jar when it starts, so it is pushed every time.

"""
    Camera

Where frames come from. A camera implements `size(cam)`, the frame's size,
`frame!(dest, cam; timeout)`, the next frame copied into `dest`, an `img[x, y]`
matrix of `RGB{N0f8}`, and `close(cam)`.
"""
abstract type Camera end

"""
    frame(cam) -> Matrix{RGB{N0f8}}

The next frame, `img[x, y]`, in a new matrix.
"""
frame(cam::Camera; kw...) = frame!(Matrix{RGB{N0f8}}(undef, size(cam)), cam; kw...)

"""
    PhoneCamera(; camera_id = 0, size = (4624, 3472), fps = 10, torch = false,
                bitrate = 40_000_000, server = <assets/scrcpy-server>, version = "4.1")

The back camera of the phone connected over adb, streamed at `size`, which
must be one of the sizes `scrcpy --list-camera-sizes` prints. At 4624x3472 an
A4 sheet that fills the frame comes out at better than 300 dpi, so every frame
is good enough to keep.

`torch=true` turns on the camera LED continuously while streaming.
`version` has to match the server jar exactly. Close the camera with `close`.
"""
mutable struct PhoneCamera <: Camera
    width::Int
    height::Int
    port::Int
    server::Base.Process
    socket::Sockets.TCPSocket
    decoder::Base.Process
    log::IOBuffer
    front::Matrix{RGB{N0f8}}
    back::Matrix{RGB{N0f8}}
    decoded::Int
    delivered::Int
    condition::Threads.Condition
    tasks::Vector{Task}
end

default_server() = joinpath(dirname(@__DIR__), "assets", "scrcpy-server")

function PhoneCamera(; camera_id::Int = 0, size::NTuple{2, Int} = (4624, 3472), fps::Int = 10, torch::Bool = false, bitrate::Int = 40_000_000, server::String = default_server(), version::String = "4.1", connect_timeout = 10.0)
    remote = "/data/local/tmp/paperhawk-server.jar"
    run(pipeline(`adb push $server $remote`; stdout = devnull))
    scid = string(rand(UInt32) & 0x7fffffff; base = 16, pad = 8)
    port = parse(Int, strip(read(`adb forward tcp:0 localabstract:scrcpy_$scid`, String)))
    options = [
        "scid=$scid", "log_level=info", "tunnel_forward=true", "audio=false", "control=false",
        "send_device_meta=false", "send_frame_meta=false", "send_stream_meta=true", "send_dummy_byte=true",
        "video_source=camera", "camera_id=$camera_id", "camera_size=$(size[1])x$(size[2])",
        "camera_torch=$torch",
        "video_codec=h265", "video_bit_rate=$bitrate", "max_fps=$fps",
    ]
    log = IOBuffer()
    proc = run(pipeline(`adb shell CLASSPATH=$remote app_process / com.genymobile.scrcpy.Server $version $options`; stdout = log, stderr = log); wait = false)
    socket = connect_server(port, proc, log; timeout = connect_timeout)
    # The stream starts with the codec, a flag word, and the frame's size.
    header = read(socket, 16)
    codec = String(header[1:4])
    codec == "h265" || error("unexpected codec $(repr(codec)) from the scrcpy server")
    width = Int(ntoh(reinterpret(UInt32, header[9:12])[1]))
    height = Int(ntoh(reinterpret(UInt32, header[13:16])[1]))
    decoder = open(pipeline(`$(FFMPEG_jll.ffmpeg()) -hide_banner -loglevel error -flags low_delay -probesize 32 -analyzeduration 0 -f hevc -i pipe:0 -fps_mode passthrough -f rawvideo -pix_fmt rgb24 pipe:1`; stderr = log), "r+")
    cam = PhoneCamera(width, height, port, proc, socket, decoder, log, Matrix{RGB{N0f8}}(undef, width, height), Matrix{RGB{N0f8}}(undef, width, height), 0, 0, Threads.Condition(), Task[])
    push!(cam.tasks, Threads.@spawn pump(cam))
    push!(cam.tasks, Threads.@spawn decode_frames(cam))
    return cam
end

"""
    connect_server(port, proc, log; timeout)

The socket to the server, once it listens. `adb forward` accepts a connection
even before the server does and then drops it; a connection the server took
starts with one dummy byte.
"""
function connect_server(port::Int, proc::Base.Process, log::IOBuffer; timeout = 10.0)
    deadline = time() + timeout
    while time() < deadline
        process_exited(proc) && error("scrcpy server exited:\n", String(take!(log)))
        socket = Sockets.connect(port)
        dummy = try
            read(socket, UInt8)
        catch
            nothing
        end
        dummy === nothing || return socket
        close(socket)
        sleep(0.1)
    end
    kill(proc)
    error("scrcpy server did not accept a connection within $timeout s:\n", String(take!(log)))
end

# Socket to decoder: the H.265 stream, as it arrives.
function pump(cam::PhoneCamera)
    try
        while !eof(cam.socket)
            write(cam.decoder, readavailable(cam.socket))
        end
    catch err
        isopen(cam.socket) && @error "camera stream broke" exception = err
    finally
        close(cam.decoder.in)
    end
end

# Decoder to frames: whole RGB frames into the back buffer, then swapped to the front.
function decode_frames(cam::PhoneCamera)
    try
        while !eof(cam.decoder)
            read!(cam.decoder, cam.back)
            lock(cam.condition) do
                cam.front, cam.back = cam.back, cam.front
                cam.decoded += 1
                notify(cam.condition)
            end
        end
    catch err
        process_running(cam.decoder) && @error "camera decoder broke" exception = err
    end
end

"""
    frame!(dest, cam; timeout = 5) -> dest

Copies into `dest` the next frame `cam` has not handed out yet, waiting for it
if need be.
"""
function frame!(dest::Matrix{RGB{N0f8}}, cam::PhoneCamera; timeout = 5.0)
    deadline = time() + timeout
    lock(cam.condition) do
        while cam.decoded <= cam.delivered
            process_running(cam.decoder) || error("camera stream ended:\n", String(take!(cam.log)))
            time() > deadline && error("no camera frame within $timeout s")
            # Wake up now and then to check the deadline.
            t = Timer(_ -> lock(() -> notify(cam.condition), cam.condition), 0.25)
            wait(cam.condition)
            close(t)
        end
        copyto!(dest, cam.front)
        cam.delivered = cam.decoded
    end
    return dest
end

Base.size(cam::PhoneCamera) = (cam.width, cam.height)

function Base.close(cam::PhoneCamera)
    close(cam.socket)
    process_running(cam.decoder) && kill(cam.decoder)
    process_running(cam.server) && kill(cam.server)
    run(pipeline(ignorestatus(`adb forward --remove tcp:$(cam.port)`); stderr = devnull))
    return nothing
end

Base.show(io::IO, cam::PhoneCamera) = print(io, "PhoneCamera(", cam.width, "x", cam.height, ", ", cam.decoded, " frames)")
