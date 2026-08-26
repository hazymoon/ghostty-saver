import Foundation
import SaverCore

// Diagnostics for "the terminal never answered".
// Separates "the APC never reached the terminal at all" from "only t=s
// (shared memory) is failing".

/// Collects every byte that arrives before the deadline, without splitting it
/// into APCs.
private func collectRaw(fd: Int32, timeout: TimeInterval) -> [UInt8] {
    var collected: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 256)
    let deadline = monotonicNow() + timeout

    while true {
        let remainingMs = Int32((deadline - monotonicNow()) * 1000)
        if remainingMs <= 0 { break }
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, remainingMs)
        if ready <= 0 { break }
        let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n <= 0 { break }
        collected.append(contentsOf: chunk[0..<n])
    }
    return collected
}

/// Makes control characters visible.
private func readable(_ bytes: [UInt8]) -> String {
    guard !bytes.isEmpty else { return "(no reply)" }
    var out = ""
    for byte in bytes {
        switch byte {
        case 0x1b: out += "<ESC>"
        case 0x07: out += "<BEL>"
        case 0x0a: out += "<LF>"
        case 0x0d: out += "<CR>"
        case 0x20...0x7e: out.append(Character(UnicodeScalar(byte)))
        default: out += String(format: "<%02x>", byte)
        }
    }
    return out
}

private func report(_ fd: Int32, _ text: String) {
    // Raw mode is on, so newlines have to be CR+LF.
    let line = text + "\r\n"
    _ = line.withCString { write(fd, $0, strlen($0)) }

    // The screen is wiped on keypress, so mirror to standard error when it has
    // been redirected. If it is still a tty this would only double up.
    if isatty(STDERR_FILENO) != 1 {
        let logLine = text + "\n"
        _ = logLine.withCString { write(STDERR_FILENO, $0, strlen($0)) }
    }
}

/// Runs the diagnostics. The caller is expected to have entered raw mode.
func runProbe(fd: Int32, size: TerminalSize) {
    func environmentValue(_ key: String) -> String {
        ProcessInfo.processInfo.environment[key] ?? "(unset)"
    }

    report(fd, "")
    report(fd, "=== diagnostics ===")
    report(fd, "TERM         : \(environmentValue("TERM"))")
    report(fd, "TERM_PROGRAM : \(environmentValue("TERM_PROGRAM"))")
    report(fd, "TMUX         : \(environmentValue("TMUX"))")
    report(fd, "winsize      : \(size.columns) cols x \(size.rows) rows / "
        + "\(size.pixelWidth) x \(size.pixelHeight) px "
        + "(cell \(size.columns > 0 ? size.pixelWidth / size.columns : 0)"
        + " x \(size.rows > 0 ? size.pixelHeight / size.rows : 0) px)")
    report(fd, "")

    // Drop anything already queued, such as a reply from a previous run.
    _ = collectRaw(fd: fd, timeout: 0.05)

    func step(_ label: String, _ sequence: [UInt8], timeout: TimeInterval = 1.0) -> [UInt8] {
        _ = sequence.withUnsafeBufferPointer { try? writeAll(fd, $0.baseAddress!, $0.count) }
        let response = collectRaw(fd: fd, timeout: timeout)
        report(fd, "\(label)")
        report(fd, "  -> \(readable(response))")
        return response
    }

    // 1. The standard kitty graphics support query. An OK means the APC reaches
    //    the terminal and the reply makes it back.
    let queryResponse = step(
        "[1] KGP support query (a=q, t=d)",
        Array("\u{1b}_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\u{1b}\\".utf8)
    )

    // 2. Inline image data (t=d). If this works the display path is alive.
    let direct = [UInt8](repeating: 0, count: 4 * 4 * 4).enumerated().map { index, _ -> UInt8 in
        index % 4 == 3 ? 255 : (index % 4 == 0 ? 255 : 0)   // opaque red
    }
    let directPayload = Data(direct).base64EncodedString()
    _ = step(
        "[2] direct transfer (a=T, t=d, 4x4)",
        Array("\u{1b}_Ga=T,f=32,s=4,v=4,i=32,p=1,q=0,C=1;\(directPayload)\u{1b}\\".utf8)
    )

    // 3. Shared memory (t=s). Failing only here points at the name, the size or
    //    the permissions.
    let probeWidth = 64
    let probeHeight = 64
    do {
        let frame = try ShmFrame.create(
            name: makeShmName(pid: getpid(), counter: 0xffff),
            payloadBytes: probeWidth * probeHeight * 4
        )
        GradientRenderer(width: probeWidth, height: probeHeight).render(into: frame.base, frame: 0)
        frame.closeMapping()
        let namePayload = Data(frame.name.utf8).base64EncodedString()
        report(fd, "  shm name: \(frame.name) (\(frame.name.utf8.count) bytes) -> base64: \(namePayload)")
        _ = step(
            "[3] shared memory transfer (a=T, t=s, 64x64)",
            Array("\u{1b}_Ga=T,f=32,s=\(probeWidth),v=\(probeHeight),t=s,i=33,p=1,q=0,C=1;\(namePayload)\u{1b}\\".utf8)
        )
    } catch {
        report(fd, "[3] shared memory transfer: could not create the segment -> \(error)")
    }

    report(fd, "")
    if queryResponse.isEmpty {
        report(fd, "verdict: not even [1] answered. The APC is not reaching the terminal,")
        report(fd, "         or something is intercepting the reply.")
        if ProcessInfo.processInfo.environment["TMUX"] != nil {
            report(fd, "         TMUX is set, so this is most likely running inside a tmux pane.")
        }
    } else {
        report(fd, "verdict: [1] answered, so KGP is reaching the terminal. Compare [2] and [3].")
    }
    report(fd, "")
    report(fd, "Press any key to exit.")
    var discard: UInt8 = 0
    _ = read(fd, &discard, 1)
}
