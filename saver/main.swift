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
    var verify = false
    var stats = false
}

let availableShaders = GeneratedShaders.all.map(\.name).joined(separator: ", ")

let usage = """
usage: ghostty-saver [options]

  --shader NAME     which shader to use (default: the first). available: \(availableShaders)
  --size WxH        state the resolution instead of asking the terminal
  --seconds N       stop after N seconds (default: run until a key is pressed)
  --frames N        stop after N frames
  --fps N           target frame rate (default 60, 0 for uncapped)
  --quiet-level N   0=replies on (default), 1=errors only, 2=no replies
  --verify          render one frame without a terminal and check shared memory
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

func selectShader(named name: String?) -> ShaderProgram {
    guard let name else {
        guard let first = GeneratedShaders.all.first else {
            fail("no shaders were generated; run Scripts/build-shaders.sh")
        }
        return first
    }
    guard let program = GeneratedShaders.all.first(where: { $0.name == name }) else {
        fail("no shader named \(name); available: \(availableShaders)")
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

/// Renders without a terminal and reads the result straight out of shared memory.
func runVerify(program: ShaderProgram, width: Int, height: Int) -> Never {
    prepareShmTracking()
    let renderer = makeRenderer(program: program, width: width, height: height)

    guard var state = ShadertoyState(device: renderer.device, width: renderer.width, height: renderer.height) else {
        fail("could not allocate the uniform buffer")
    }
    state.update(time: 0, frame: 0, frameRate: 0)

    report("device        : \(renderer.device.name)")
    report("shader        : \(program.name) (entry point \(program.entryPoint))")
    report("requested     : \(width) x \(height)")
    report("actual        : \(renderer.width) x \(renderer.height) "
        + "(bytesPerRow=\(renderer.bytesPerRow), rounded up to the linear texture alignment)")
    report("uniform       : \(ShadertoyUniformLayout.size) bytes")

    do {
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
        frame.closeMapping()
    } catch {
        fail("\(error)")
    }

    unlinkTrackedShm()
    exit(0)
}

// MARK: - Startup

let options = parseOptions()
let program = selectShader(named: options.shaderName)

if options.verify {
    let size = options.explicitSize ?? (width: 1920, height: 1080)
    runVerify(program: program, width: size.width, height: size.height)
}

let outputIsTTY = TerminalSession.openOutput(sinkPath: nil)
guard outputIsTTY else { fail("not attached to a terminal (use --verify to check without one)") }

let size: TerminalSize
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

let transport = KittySharedMemoryTransport(
    fd: TerminalSession.outputFD,
    width: renderer.width,
    height: renderer.height,
    quiet: options.quiet
)
let reader = ResponseReader(fd: TerminalSession.outputFD)

var shmSamples = Samples()
var renderSamples = Samples()
var writeSamples = Samples()
var ackSamples = Samples()

let frameInterval = options.targetFPS > 0 ? 1 / options.targetFPS : 0
let startedAt = monotonicNow()
var frameIndex: UInt64 = 0
var stopped = false

while !stopped {
    if let maxFrames = options.maxFrames, frameIndex >= UInt64(maxFrames) { break }
    if let seconds = options.seconds, monotonicNow() - startedAt >= seconds { break }

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
    shmSamples.append(monotonicNow() - shmStart)

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
    renderSamples.append(monotonicNow() - renderStart)

    frame.closeMapping()

    do {
        writeSamples.append(try transport.send(frame: frame))
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
        ackSamples.append(monotonicNow() - ackStart)
    } else {
        var pfd = pollfd(fd: TerminalSession.outputFD, events: Int16(POLLIN), revents: 0)
        if poll(&pfd, 1, 0) > 0 {
            var discard: UInt8 = 0
            if read(TerminalSession.outputFD, &discard, 1) > 0 { stopped = true }
        }
    }

    // Sleep off whatever is left of the target frame interval.
    if frameInterval > 0 {
        let remaining = frameInterval - (monotonicNow() - frameStart)
        if remaining > 0 { usleep(useconds_t(remaining * 1_000_000)) }
    }
}

let elapsed = monotonicNow() - startedAt
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
