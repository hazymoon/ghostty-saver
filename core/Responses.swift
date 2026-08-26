import Foundation

/// 端末から返ってきたもの。
public enum TerminalEvent {
    /// APC 応答（kitty graphics protocol の `ESC _ G ... ESC \`）の中身
    case response(String)
    /// APC 以外のバイト。スパイクではキー入力とみなして終了に使う。
    case userInput
    /// 期限内に何も来なかった
    case timeout
}

/// tty からの応答を APC 単位で切り出す。raw モード前提。
public final class ResponseReader {
    private let fd: Int32
    private var state: State = .idle
    private var apcBuffer: [UInt8] = []
    private var chunk = [UInt8](repeating: 0, count: 256)
    private var pending: [UInt8] = []

    private enum State {
        case idle
        case sawEscape
        case inAPC
        case inAPCSawEscape
    }

    public init(fd: Int32) {
        self.fd = fd
    }

    /// APC 応答が 1 件揃うか、APC 以外のバイトを見るか、期限切れになるまで待つ。
    public func next(timeout: TimeInterval) -> TerminalEvent {
        let deadline = monotonicNow() + timeout

        while true {
            // 前回の read で余ったバイトを先に消化する
            while !pending.isEmpty {
                let byte = pending.removeFirst()
                if let event = feed(byte) { return event }
            }

            let remainingMs = Int32((deadline - monotonicNow()) * 1000)
            if remainingMs <= 0 { return .timeout }

            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, remainingMs)
            if ready == 0 { return .timeout }
            if ready < 0 {
                if errno == EINTR { continue }
                return .timeout
            }

            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                return .timeout
            }
            pending.append(contentsOf: chunk[0..<n])
        }
    }

    private func feed(_ byte: UInt8) -> TerminalEvent? {
        switch state {
        case .idle:
            if byte == 0x1b { state = .sawEscape; return nil }
            return .userInput

        case .sawEscape:
            if byte == UInt8(ascii: "_") {
                state = .inAPC
                apcBuffer.removeAll(keepingCapacity: true)
                return nil
            }
            // APC ではない ESC シーケンス。キー入力（矢印キー等）とみなす。
            state = .idle
            return .userInput

        case .inAPC:
            if byte == 0x1b { state = .inAPCSawEscape; return nil }
            apcBuffer.append(byte)
            return nil

        case .inAPCSawEscape:
            if byte == UInt8(ascii: "\\") {
                state = .idle
                return .response(String(decoding: apcBuffer, as: UTF8.self))
            }
            apcBuffer.append(0x1b)
            apcBuffer.append(byte)
            state = .inAPC
            return nil
        }
    }
}
