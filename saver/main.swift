import Foundation
import GeneratedShaders
import Metal
import SaverCore

// Puts the render target directly in shared memory and ships what the GPU drew
// through the kitty graphics protocol.
//
// Shaders come from shaders/*.glsl (Shadertoy form), converted to MSL by
// Scripts/build-shaders.sh. The uniform declarations are Ghostty's own
// shadertoy_prefix.glsl, so the same .glsl also works as a Ghostty
// custom-shader.

// MARK: - Options

struct Options {
    var explicitSize: (width: Int, height: Int)?
    var seconds: Double?
    var maxFrames: Int?
    var targetFPS: Double = 60
    var quiet: QuietLevel = .verbose
    var shaderName: String?
    var listShaders = false
    var verify = false
    var dumpPath: String?
    var dumpTime: Double = 0
    var stats = false
}

let availableShaders = GeneratedShaders.all.map(\.name).joined(separator: ", ")

let usage = """
usage: ghostty-saver [options]

  --shader NAME     which shader to use (default: \(ShaderCatalog.defaultName)),
                    or \(ShaderCatalog.randomName) to pick one for you
  --list-shaders    list the shaders and what they draw, then exit
  --size WxH        state the resolution instead of asking the terminal
  --seconds N       stop after N seconds (default: run until a key is pressed)
  --frames N        stop after N frames; with --dump, how many to write
  --fps N           target frame rate (default 60, 0 for uncapped)
  --quiet-level N   0=replies on (default), 1=errors only, 2=no replies
  --verify          render one frame without a terminal and check shared memory
  --dump PATH       with --verify, also write the frame to PATH as a PNG.
                    with --frames, PATH is a directory and the frames are
                    written to it as a numbered sequence, 1/--fps apart
  --at SECONDS      with --dump, the iTime of the first frame (default 0)
  --stats           print a per-frame breakdown on exit
  -h, --help        show this message
"""

func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())

    func nextValue(_ flag: String) -> String {
        guard !arguments.isEmpty else {
            FileHandle.standardError.write(Data("\(flag) needs a value\n".utf8))
            exit(2)
        }
        return arguments.removeFirst()
    }

    while !arguments.isEmpty {
        let argument = arguments.removeFirst()
        switch argument {
        case "-h", "--help":
            print(usage)
            exit(0)
        case "--shader":
            options.shaderName = nextValue(argument)
        case "--list-shaders":
            options.listShaders = true
        case "--size":
            let value = nextValue(argument)
            let parts = value.lowercased().split(separator: "x")
            guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 else {
                FileHandle.standardError.write(Data("--size expects WxH: \(value)\n".utf8))
                exit(2)
            }
            options.explicitSize = (w, h)
        case "--seconds":
            options.seconds = Double(nextValue(argument))
        case "--frames":
            options.maxFrames = Int(nextValue(argument))
        case "--fps":
            options.targetFPS = Double(nextValue(argument)) ?? 60
        case "--quiet-level":
            options.quiet = QuietLevel(rawValue: Int(nextValue(argument)) ?? 0) ?? .verbose
        case "--verify":
            options.verify = true
        case "--dump":
            options.dumpPath = nextValue(argument)
            options.verify = true
        case "--at":
            options.dumpTime = Double(nextValue(argument)) ?? 0
        case "--stats":
            options.stats = true
        default:
            FileHandle.standardError.write(Data("unknown option: \(argument)\n\n\(usage)\n".utf8))
            exit(2)
        }
    }
    return options
}

func fail(_ message: String) -> Never {
    TerminalSession.restore()
    FileHandle.standardError.write(Data("ghostty-saver: \(message)\n".utf8))
    exit(1)
}

func report(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

/// Prints the catalog, padded to the widest name so the summaries line up.
func listShaders() -> Never {
    let width = GeneratedShaders.all.map(\.name.count).max() ?? 0
    for program in GeneratedShaders.all {
        let padding = String(repeating: " ", count: width - program.name.count)
        print("\(program.name)\(padding)  \(program.summary)")
    }
    exit(0)
}

func selectShader(named name: String?) -> ShaderProgram {
    guard !GeneratedShaders.all.isEmpty else {
        fail("no shaders were generated; run Scripts/build-shaders.sh")
    }
    guard let program = ShaderCatalog.select(named: name, from: GeneratedShaders.all) else {
        fail("no shader named \(name ?? ShaderCatalog.defaultName); available: \(availableShaders)")
    }
    return program
}

func makeRenderer(program: ShaderProgram, width: Int, height: Int) -> MetalRenderer {
    do {
        return try MetalRenderer(
            width: width,
            height: height,
            fragmentSource: program.source,
            fragmentFunctionName: program.entryPoint
        )
    } catch {
        fail("\(error)")
    }
}

// MARK: - Verification

/// Renders without a terminal and reads the result straight out of shared
/// memory.
///
/// With `--frames`, the dump path is a directory rather than a file and the
/// render becomes a numbered sequence, one frame every 1/`--fps` of iTime
/// starting at `--at`. That is what `Scripts/record-demo.sh` turns into the
/// animation in the README, and the reason it works that way is that the
/// frames then come off the same Metal path the screensaver runs on, rather
/// than out of a second renderer written to look like it.
func runVerify(
    program: ShaderProgram,
    width: Int,
    height: Int,
    dumpPath: String?,
    time: Double,
    frames: Int?,
    fps: Double
) -> Never {
    prepareShmTracking()
    let renderer = makeRenderer(program: program, width: width, height: height)

    guard var state = ShadertoyState(device: renderer.device, width: renderer.width, height: renderer.height) else {
        fail("could not allocate the uniform buffer")
    }

    // A sequence is a dump with a count: --frames on its own has nowhere to put
    // anything, and --dump on its own is the single frame it always was.
    let count = dumpPath == nil ? nil : frames
    if count != nil, !(fps > 0) {
        fail("--fps has to be above zero to space out a sequence of frames")
    }
    let rate = fps > 0 ? fps : 60
    let firstFrame = Int((time * rate).rounded())

    state.update(time: Float(time), frame: firstFrame, frameRate: Float(rate))

    report("device        : \(renderer.device.name)")
    report("shader        : \(program.name) (entry point \(program.entryPoint))")
    report("requested     : \(width) x \(height)")
    report("actual        : \(renderer.width) x \(renderer.height) "
        + "(bytesPerRow=\(renderer.bytesPerRow), rounded up to the linear texture alignment)")
    report("uniform       : \(ShadertoyUniformLayout.size) bytes")

    do {
        // One segment for the whole run. The screensaver needs a fresh one per
        // frame because the terminal unlinks each after reading it; nothing is
        // reading these.
        let frame = try ShmFrame.create(
            name: makeShmName(pid: getpid(), counter: 0),
            payloadBytes: renderer.payloadBytes
        )
        try renderer.render(into: frame, uniforms: state.uniforms)

        // Read shared memory directly; the GPU writes should be sitting there.
        let pixels = frame.base.assumingMemoryBound(to: UInt8.self)
        func pixel(_ x: Int, _ y: Int) -> String {
            let offset = y * renderer.bytesPerRow + x * 4
            return "(\(pixels[offset]),\(pixels[offset + 1]),\(pixels[offset + 2]),\(pixels[offset + 3]))"
        }
        report("shared memory contents (RGBA)")
        report("  top-left \(pixel(0, 0))  top-right \(pixel(renderer.width - 1, 0))")
        report("  bottom-left \(pixel(0, renderer.height - 1))  bottom-right \(pixel(renderer.width - 1, renderer.height - 1))")

        func writeFrame(to path: String) throws {
            try FrameDump.writePNG(
                pixels: frame.base,
                width: renderer.width,
                height: renderer.height,
                bytesPerRow: renderer.bytesPerRow,
                to: path
            )
        }

        if let dumpPath {
            if let count {
                guard count > 0 else { fail("--frames has to be above zero") }
                try FileManager.default.createDirectory(
                    atPath: dumpPath, withIntermediateDirectories: true
                )
                // Zero padded, so the sequence sorts the way ffmpeg reads it.
                for index in 0..<count {
                    let at = time + Double(index) / rate
                    state.update(time: Float(at), frame: firstFrame + index, frameRate: Float(rate))
                    try renderer.render(into: frame, uniforms: state.uniforms)
                    let name = String(format: "%05d.png", index)
                    try writeFrame(to: (dumpPath as NSString).appendingPathComponent(name))
                }
                let last = time + Double(count - 1) / rate
                report("wrote \(count) frames to \(dumpPath)/ "
                    + "(iTime \(String(format: "%.3f", time)) to \(String(format: "%.3f", last)) at \(rate) fps)")
            } else {
                try writeFrame(to: dumpPath)
                report("wrote \(dumpPath)")
            }
        }

        frame.closeMapping()
    } catch {
        fail("\(error)")
    }

    unlinkTrackedShm()
    exit(0)
}

// MARK: - Startup

let options = parseOptions()

if options.listShaders { listShaders() }

let program = selectShader(named: options.shaderName)

if options.verify {
    let size = options.explicitSize ?? (width: 1920, height: 1080)
    runVerify(
        program: program,
        width: size.width,
        height: size.height,
        dumpPath: options.dumpPath,
        time: options.dumpTime,
        frames: options.maxFrames,
        fps: options.targetFPS
    )
}

let outputIsTTY = TerminalSession.openOutput(sinkPath: nil)
guard outputIsTTY else { fail("not attached to a terminal (use --verify to check without one)") }

var size: TerminalSize
if let explicit = options.explicitSize {
    size = TerminalSize(pixelWidth: explicit.width, pixelHeight: explicit.height, columns: 0, rows: 0)
} else {
    do {
        size = try resolveTerminalSize(fd: TerminalSession.outputFD)
    } catch {
        fail("could not determine the terminal size: \(error)")
    }
}

let renderer = makeRenderer(program: program, width: size.pixelWidth, height: size.pixelHeight)
guard var state = ShadertoyState(device: renderer.device, width: renderer.width, height: renderer.height) else {
    fail("could not allocate the uniform buffer")
}

TerminalSession.prepare()
TerminalSession.enterRawMode()
TerminalSession.enterAltScreen()
TerminalSession.hideCursor()

var transport = KittySharedMemoryTransport(
    fd: TerminalSession.outputFD,
    width: renderer.width,
    height: renderer.height,
    quiet: options.quiet
)
let reader = ResponseReader(fd: TerminalSession.outputFD)

// Only collected with --stats: one Double per frame per series is small, but a
// screensaver runs for hours and nothing ever reads them otherwise.
var shmSamples = Samples()
var renderSamples = Samples()
var writeSamples = Samples()
var ackSamples = Samples()

let startedAt = monotonicNow()
var pacer = FramePacer(targetFPS: options.targetFPS, now: startedAt)
var frameIndex: UInt64 = 0
var stopped = false

/// Re-measures the terminal and rebuilds everything that was sized to it.
/// The pipeline does not depend on the size, so the shader is not recompiled.
func adoptNewTerminalSize() {
    guard let updated = try? resolveTerminalSize(fd: TerminalSession.outputFD),
          updated.hasPixels else { return }
    guard updated.pixelWidth != size.pixelWidth || updated.pixelHeight != size.pixelHeight else { return }

    size = updated
    renderer.resize(width: updated.pixelWidth, height: updated.pixelHeight)
    state.setResolution(width: renderer.width, height: renderer.height)
    transport = KittySharedMemoryTransport(
        fd: TerminalSession.outputFD,
        width: renderer.width,
        height: renderer.height,
        quiet: options.quiet
    )
    // The stored image is the old size, so drop it rather than leaving a
    // stale placement behind while the new one is transmitted.
    try? transport.deleteAll()
}

while !stopped {
    if let maxFrames = options.maxFrames, frameIndex >= UInt64(maxFrames) { break }
    if let seconds = options.seconds, monotonicNow() - startedAt >= seconds { break }
    if TerminalSession.takeResizeRequest() { adoptNewTerminalSize() }

    let frameStart = monotonicNow()

    // The terminal unlinks a segment once it has read it, so every frame needs a new one.
    let shmStart = monotonicNow()
    let frame: ShmFrame
    do {
        frame = try ShmFrame.create(
            name: makeShmName(pid: getpid(), counter: frameIndex),
            payloadBytes: renderer.payloadBytes
        )
    } catch {
        fail("\(error)")
    }
    if options.stats { shmSamples.append(monotonicNow() - shmStart) }

    let renderStart = monotonicNow()
    state.update(
        time: Float(frameStart - startedAt),
        frame: Int(frameIndex),
        frameRate: Float(options.targetFPS)
    )
    do {
        try renderer.render(into: frame, uniforms: state.uniforms)
    } catch {
        fail("\(error)")
    }
    if options.stats { renderSamples.append(monotonicNow() - renderStart) }

    frame.closeMapping()

    do {
        let writeDuration = try transport.send(frame: frame)
        if options.stats { writeSamples.append(writeDuration) }
    } catch {
        fail("\(error)")
    }
    frameIndex += 1

    if options.quiet != .silent {
        let ackStart = monotonicNow()
        switch reader.next(timeout: 2.0) {
        case .response:
            break
        case .userInput:
            stopped = true
        case .timeout:
            TerminalSession.restore()
            report("no reply from the terminal (frame \(frameIndex))")
            exit(1)
        }
        if options.stats { ackSamples.append(monotonicNow() - ackStart) }
    } else {
        var pfd = pollfd(fd: TerminalSession.outputFD, events: Int16(POLLIN), revents: 0)
        if poll(&pfd, 1, 0) > 0 {
            var discard: UInt8 = 0
            if read(TerminalSession.outputFD, &discard, 1) > 0 { stopped = true }
        }
    }

    let wait = pacer.sleepInterval(now: monotonicNow())
    if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
}

let elapsed = monotonicNow() - startedAt

// The reply to the last frame is still unread when a keypress ends the loop.
TerminalSession.discardPendingInput()
TerminalSession.restore()

if options.stats {
    report("")
    report("=== ghostty-saver ===")
    report("device         : \(renderer.device.name)")
    report("shader         : \(program.name)")
    report("resolution     : \(renderer.width) x \(renderer.height) px "
        + "(terminal reports \(size.pixelWidth) x \(size.pixelHeight))")
    report("per frame      : \(String(format: "%.2f", Double(renderer.payloadBytes) / 1_048_576)) MiB")
    report("frames         : \(frameIndex)")
    report("elapsed        : \(String(format: "%.3f", elapsed)) s")
    report("effective fps  : \(String(format: "%.2f", elapsed > 0 ? Double(frameIndex) / elapsed : 0))")
    report("")
    report("per-frame breakdown (ms)")
    report("  shm create   : \(shmSamples.summaryMilliseconds())")
    report("  GPU render   : \(renderSamples.summaryMilliseconds())")
    report("  write(2)     : \(writeSamples.summaryMilliseconds())")
    if ackSamples.count > 0 {
        report("  terminal ack : \(ackSamples.summaryMilliseconds())")
    }
}
