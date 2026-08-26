import Foundation
import CShim

/// 端末の実ピクセルサイズとセル数。
struct TerminalSize {
    var pixelWidth: Int
    var pixelHeight: Int
    var columns: Int
    var rows: Int

    var hasPixels: Bool { pixelWidth > 0 && pixelHeight > 0 }
}

enum TerminalSizeError: Error, CustomStringConvertible {
    case notATTY
    case ioctlFailed(errno: Int32)
    case noPixelSize
    case csi14tTimeout
    case csi14tUnparsable(String)

    var description: String {
        switch self {
        case .notATTY:
            return "標準出力が tty ではない（--size WxH で明示指定してください）"
        case .ioctlFailed(let e):
            return "TIOCGWINSZ に失敗: errno=\(e) (\(String(cString: strerror(e))))"
        case .noPixelSize:
            return "ws_xpixel / ws_ypixel が 0 で、CSI 14 t のフォールバックも失敗した"
        case .csi14tTimeout:
            return "CSI 14 t の応答が来なかった"
        case .csi14tUnparsable(let s):
            return "CSI 14 t の応答を解釈できなかった: \(s.debugDescription)"
        }
    }
}

/// TIOCGWINSZ でサイズを取得する。ws_xpixel/ws_ypixel が 0 のことがある。
func queryWinsize(fd: Int32) throws -> TerminalSize {
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

/// `CSI 14 t` を送り `CSI 4 ; height ; width t` の応答を読む。
/// 呼び出し側が raw モードにしてあることを前提とする。
func queryCSI14t(fd: Int32, timeout: TimeInterval = 0.5) throws -> (width: Int, height: Int) {
    let query = "\u{1b}[14t"
    _ = query.withCString { write(fd, $0, strlen($0)) }

    let deadline = Date().addingTimeInterval(timeout)
    var buf = [UInt8]()
    var byte: UInt8 = 0

    while Date() < deadline {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let remaining = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
        let ready = poll(&pfd, 1, remaining)
        if ready <= 0 { continue }
        let n = read(fd, &byte, 1)
        if n <= 0 { continue }
        buf.append(byte)
        // 応答終端は 't'
        if byte == UInt8(ascii: "t") { break }
        if buf.count > 64 { break }
    }

    guard !buf.isEmpty else { throw TerminalSizeError.csi14tTimeout }
    let response = String(decoding: buf, as: UTF8.self)

    // 期待形式: ESC [ 4 ; <height> ; <width> t
    let numbers = response
        .split(whereSeparator: { !$0.isNumber })
        .compactMap { Int($0) }
    guard numbers.count >= 3, numbers[0] == 4 else {
        throw TerminalSizeError.csi14tUnparsable(response)
    }
    return (width: numbers[2], height: numbers[1])
}

/// TIOCGWINSZ を第一手段、CSI 14 t をフォールバックとしてピクセルサイズを決める。
/// CSI 14 t を使う場合だけ一時的に raw モードへ落とす。
func resolveTerminalSize(fd: Int32) throws -> TerminalSize {
    guard isatty(fd) == 1 else { throw TerminalSizeError.notATTY }

    var size = try queryWinsize(fd: fd)
    if size.hasPixels { return size }

    var original = termios()
    guard tcgetattr(fd, &original) == 0 else { throw TerminalSizeError.noPixelSize }
    var raw = original
    cfmakeraw(&raw)
    guard tcsetattr(fd, TCSANOW, &raw) == 0 else { throw TerminalSizeError.noPixelSize }
    defer { tcsetattr(fd, TCSANOW, &original) }

    let pixels = try queryCSI14t(fd: fd)
    size.pixelWidth = pixels.width
    size.pixelHeight = pixels.height
    guard size.hasPixels else { throw TerminalSizeError.noPixelSize }
    return size
}
