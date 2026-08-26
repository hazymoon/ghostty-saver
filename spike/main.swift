import Foundation
import SaverCore

// Transfer spike.
//
// Pushes a CPU-generated gradient through the kitty graphics protocol's shared
// memory transfer (a=T, t=s) and measures the achievable frame rate along with
// a per-frame breakdown. This exists to answer one question before any Metal
// code is written: does the transfer path clear 30fps?

// MARK: - Options

struct Options {
    var explicitSize: (width: Int, height: Int)?
    var seconds: Double = 5
    var maxFrames: Int?
    var quiet: QuietLevel = .verbose
    var sinkPath: String?
    var useAltScreen = true
    var ackTimeout: Double = 2.0
    /// Keep the last frame on screen and wait for a keypress.
    var hold = false
    /// Skip measurement and only diagnose why replies are missing.
    var probe = false
}

let usage = """
usage: spike [options]

  --size WxH        state the resolution instead of asking the terminal
  --seconds N       how long to measure (default 5)
  --frames N        stop after N frames; takes precedence over --seconds
  --once            send a single frame and hold it until a key is pressed
  --hold            hold the last frame until a key is pressed
  --quiet-level N   0=replies on (default), 1=errors only, 2=no replies
  --sink PATH       write to PATH instead of the tty, to measure everything but
                    the terminal
  --probe           skip measurement; diagnose whether KGP arrives and whether
                    t=d or t=s is the one failing
  --no-alt-screen   stay on the primary screen
  -h, --help        show this message

The default of --quiet-level 0 waits for one reply per frame, which makes the
effective frame rate reflect what the terminal actually consumed.
--quiet-level 2 measures the send side's ceiling and says nothing about how
fast the terminal draws.
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
        case "--size":
            let value = nextValue(argument)
            let parts = value.lowercased().split(separator: "x")
            guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 else {
                FileHandle.standardError.write(Data("--size expects WxH: \(value)\n".utf8))
                exit(2)
            }
            options.explicitSize = (w, h)
        case "--seconds":
            options.seconds = Double(nextValue(argument)) ?? options.seconds
        case "--frames":
            options.maxFrames = Int(nextValue(argument))
        case "--once":
            options.maxFrames = 1
            options.hold = true
        case "--hold":
            options.hold = true
        case "--quiet-level":
            let value = Int(nextValue(argument)) ?? 0
            options.quiet = QuietLevel(rawValue: value) ?? .verbose
        case "--sink":
            options.sinkPath = nextValue(argument)
        case "--probe":
            options.probe = true
            options.useAltScreen = false
        case "--no-alt-screen":
            options.useAltScreen = false
        default:
            FileHandle.standardError.write(Data("unknown option: \(argument)\n\n\(usage)\n".utf8))
            exit(2)
        }
    }
    return options
}

// MARK: - Failure

func fail(_ message: String) -> Never {
    TerminalSession.restore()
    FileHandle.standardError.write(Data("spike: \(message)\n".utf8))
    exit(1)
}

// MARK: - Startup

let options = parseOptions()

// Pick the output. Falls back to /dev/tty when standard output is redirected.
let outputIsTTY = TerminalSession.openOutput(sinkPath: options.sinkPath)

// Replies cannot be read without a tty, so drop to q=2 there.
var quiet = options.quiet
if !outputIsTTY && quiet != .silent {
    quiet = .silent
}

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

let width = size.pixelWidth
let height = size.pixelHeight
let payloadBytes = width * height * 4

TerminalSession.prepare()

if outputIsTTY {
    TerminalSession.enterRawMode()
    if options.useAltScreen { TerminalSession.enterAltScreen() }
    TerminalSession.hideCursor()
}

if options.probe {
    guard outputIsTTY else { fail("--probe needs a tty") }
    runProbe(fd: TerminalSession.outputFD, size: size)
    TerminalSession.restore()
    exit(0)
}

// MARK: - Measurement loop

let transport = KittySharedMemoryTransport(
    fd: TerminalSession.outputFD,
    width: width,
    height: height,
    quiet: quiet
)
let renderer = GradientRenderer(width: width, height: height)
let reader = outputIsTTY ? ResponseReader(fd: TerminalSession.outputFD) : nil

var shmCreateSamples = Samples()   // shm_open + ftruncate + mmap
var fillSamples = Samples()        // gradient generation
var unmapSamples = Samples()       // munmap + close
var writeSamples = Samples()       // write(2)
var ackSamples = Samples()         // waiting on the terminal

let pid = getpid()
var frameCounter: UInt64 = 0
var stoppedByUser = false
var ackFailure: String?
var errorResponses: [String] = []

let loopStart = monotonicNow()
let deadline = loopStart + options.seconds

while true {
    if let maxFrames = options.maxFrames, frameCounter >= UInt64(maxFrames) { break }
    if options.maxFrames == nil && monotonicNow() >= deadline { break }

    // The terminal unlinks a segment once it has read it, so every frame needs
    // a new name.
    let name = makeShmName(pid: pid, counter: frameCounter)

    let createStart = monotonicNow()
    let frame: ShmFrame
    do {
        frame = try ShmFrame.create(name: name, payloadBytes: payloadBytes)
    } catch {
        fail("\(error)")
    }
    // create() already includes the mmap, so it is billed as one step.
    let created = monotonicNow()
    shmCreateSamples.append(created - createStart)

    let fillStart = created
    renderer.render(into: frame.base, frame: frameCounter)
    let filled = monotonicNow()
    fillSamples.append(filled - fillStart)

    frame.closeMapping()
    let unmapped = monotonicNow()
    unmapSamples.append(unmapped - filled)

    do {
        writeSamples.append(try transport.send(frame: frame))
    } catch {
        fail("\(error)")
    }

    frameCounter += 1

    // With replies on, waiting for one per frame makes the terminal the pacer,
    // so the effective frame rate reflects its real throughput.
    if let reader, quiet != .silent {
        let ackStart = monotonicNow()
        var settled = false
        while !settled {
            switch reader.next(timeout: options.ackTimeout) {
            case .response(let body):
                if !body.hasSuffix("OK") { errorResponses.append(body) }
                settled = true
            case .userInput:
                stoppedByUser = true
                settled = true
            case .timeout:
                ackFailure = "no reply within \(options.ackTimeout)s (frame \(frameCounter))"
                settled = true
            }
        }
        ackSamples.append(monotonicNow() - ackStart)
        if stoppedByUser || ackFailure != nil { break }
    } else if outputIsTTY {
        // Even without replies, a keypress should still stop the loop.
        var pfd = pollfd(fd: TerminalSession.outputFD, events: Int16(POLLIN), revents: 0)
        if poll(&pfd, 1, 0) > 0 {
            var discard: UInt8 = 0
            if read(TerminalSession.outputFD, &discard, 1) > 0 { stoppedByUser = true; break }
        }
    }
}

let elapsed = monotonicNow() - loopStart

// Restoring deletes the image and leaves the alternate screen, so hold before
// that when the frame is meant to be looked at.
if options.hold && outputIsTTY && !stoppedByUser {
    var pfd = pollfd(fd: TerminalSession.outputFD, events: Int16(POLLIN), revents: 0)
    _ = poll(&pfd, 1, -1)
    var discard: UInt8 = 0
    _ = read(TerminalSession.outputFD, &discard, 1)
}

TerminalSession.restore()

// MARK: - Report

func line(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

let megabytesPerFrame = Double(payloadBytes) / 1_048_576
let fps = elapsed > 0 ? Double(frameCounter) / elapsed : 0

line("")
line("=== transfer spike ===")
line("resolution     : \(width) x \(height) px (\(size.columns) cols x \(size.rows) rows)")
line("per frame      : \(String(format: "%.2f", megabytesPerFrame)) MiB (RGBA8)")
line("reply mode     : q=\(quiet.rawValue) " + (quiet == .silent
    ? "(replies ignored: send-side ceiling, not the terminal's draw rate)"
    : "(one reply per frame: what the terminal actually consumed)"))
line("frames         : \(frameCounter)")
line("elapsed        : \(String(format: "%.3f", elapsed)) s")
line("effective fps  : \(String(format: "%.2f", fps))")
line("throughput     : \(String(format: "%.1f", megabytesPerFrame * fps)) MiB/s")
line("")
line("per-frame breakdown (ms)")
line("  shm create   : \(shmCreateSamples.summaryMilliseconds())   <- shm_open + ftruncate + mmap")
line("  generate     : \(fillSamples.summaryMilliseconds())   <- CPU gradient")
line("  unmap+close  : \(unmapSamples.summaryMilliseconds())")
line("  write(2)     : \(writeSamples.summaryMilliseconds())")
if ackSamples.count > 0 {
    line("  terminal ack : \(ackSamples.summaryMilliseconds())")
}
line("")

let selfCost = shmCreateSamples.mean + fillSamples.mean + unmapSamples.mean + writeSamples.mean
line("send side total: \(String(format: "%.3f", selfCost * 1000)) ms/frame "
    + "(ceiling \(String(format: "%.1f", selfCost > 0 ? 1 / selfCost : 0)) fps)")

if stoppedByUser { line("note: stopped by a keypress") }
if let ackFailure { line("note: \(ackFailure)") }
if !errorResponses.isEmpty {
    line("note: the terminal returned errors (\(errorResponses.count)): "
        + errorResponses.prefix(3).joined(separator: " / "))
}
if fps < 30 && ackFailure == nil && !stoppedByUser {
    line("note: below 30fps. Either drop the resolution or switch to t=t.")
}
