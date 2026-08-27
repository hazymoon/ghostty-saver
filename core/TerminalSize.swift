import Foundation
import CShim

/// The terminal's size in pixels and in cells.
public struct TerminalSize {
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var columns: Int
    public var rows: Int

    public var hasPixels: Bool { pixelWidth > 0 && pixelHeight > 0 }

    public init(pixelWidth: Int, pixelHeight: Int, columns: Int, rows: Int) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.columns = columns
        self.rows = rows
    }
}

public enum TerminalSizeError: Error, CustomStringConvertible {
    case notATTY
    case ioctlFailed(errno: Int32)
    case noPixelSize
    case csi14tTimeout
    case csi14tUnparsable(String)

    public var description: String {
        switch self {
        case .notATTY:
            return "standard output is not a tty (pass --size WxH instead)"
        case .ioctlFailed(let code):
            return "TIOCGWINSZ failed: errno=\(code) (\(String(cString: strerror(code))))"
        case .noPixelSize:
            return "ws_xpixel/ws_ypixel are zero and the CSI 14 t fallback also failed"
        case .csi14tTimeout:
            return "no reply to CSI 14 t"
        case .csi14tUnparsable(let reply):
            return "could not parse the CSI 14 t reply: \(reply.debugDescription)"
        }
    }
}

/// Asks the kernel for the size. ws_xpixel/ws_ypixel are sometimes zero.
public func queryWinsize(fd: Int32) throws -> TerminalSize {
    var ws = winsize()
    guard gs_winsize(fd, &ws) == 0 else {
        throw TerminalSizeError.ioctlFailed(errno: errno)
    }
    return TerminalSize(
        pixelWidth: Int(ws.ws_xpixel),
        pixelHeight: Int(ws.ws_ypixel),
        columns: Int(ws.ws_col),
        rows: Int(ws.ws_row)
    )
}

/// Sends `CSI 14 t` and reads the `CSI 4 ; height ; width t` reply.
/// The caller is expected to have put the terminal in raw mode.
///
/// The reply is read from `readFD`, which is expected to be non-blocking: in
/// raw mode a read that finds nothing waits for as long as the terminal takes,
/// and the deadline here bounds the loop, not a read inside it.
public func queryCSI14t(
    fd: Int32,
    readFD: Int32? = nil,
    timeout: TimeInterval = 0.5
) throws -> (width: Int, height: Int) {
    let replyFD = readFD ?? fd
    let query = "\u{1b}[14t"
    _ = query.withCString { write(fd, $0, strlen($0)) }

    let deadline = Date().addingTimeInterval(timeout)
    var buffer = [UInt8]()
    var byte: UInt8 = 0

    while Date() < deadline {
        var pfd = pollfd(fd: replyFD, events: Int16(POLLIN), revents: 0)
        let remaining = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
        let ready = poll(&pfd, 1, remaining)
        if ready <= 0 { continue }
        // POLLERR and POLLNVAL answer positively as well, and neither will
        // ever become readable, so there is nothing left to wait for.
        if pfd.revents & Int16(POLLIN) == 0 { break }
        let n = read(replyFD, &byte, 1)
        if n <= 0 { continue }
        buffer.append(byte)
        // The reply terminates with 't'.
        if byte == UInt8(ascii: "t") { break }
        if buffer.count > 64 { break }
    }

    guard !buffer.isEmpty else { throw TerminalSizeError.csi14tTimeout }
    let reply = String(decoding: buffer, as: UTF8.self)

    // Expected form: ESC [ 4 ; <height> ; <width> t
    let numbers = reply
        .split(whereSeparator: { !$0.isNumber })
        .compactMap { Int($0) }
    guard numbers.count >= 3, numbers[0] == 4 else {
        throw TerminalSizeError.csi14tUnparsable(reply)
    }
    return (width: numbers[2], height: numbers[1])
}

/// Resolves the pixel size, preferring TIOCGWINSZ and falling back to CSI 14 t.
/// Raw mode is only entered for the fallback, and restored afterwards.
public func resolveTerminalSize(fd: Int32, readFD: Int32? = nil) throws -> TerminalSize {
    guard isatty(fd) == 1 else { throw TerminalSizeError.notATTY }

    var size = try queryWinsize(fd: fd)
    if size.hasPixels { return size }

    var original = termios()
    guard tcgetattr(fd, &original) == 0 else { throw TerminalSizeError.noPixelSize }
    var raw = original
    cfmakeraw(&raw)
    guard tcsetattr(fd, TCSANOW, &raw) == 0 else { throw TerminalSizeError.noPixelSize }
    defer { tcsetattr(fd, TCSANOW, &original) }

    let pixels = try queryCSI14t(fd: fd, readFD: readFD)
    size.pixelWidth = pixels.width
    size.pixelHeight = pixels.height
    guard size.hasPixels else { throw TerminalSizeError.noPixelSize }
    return size
}
