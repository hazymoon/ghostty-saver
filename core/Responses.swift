import Foundation

/// What came back from the terminal.
public enum TerminalEvent {
    /// The body of an APC reply (`ESC _ G ... ESC \`).
    case response(String)
    /// A byte that was not part of an APC. Treated as a keypress.
    case userInput
    /// Nothing arrived before the deadline.
    case timeout
}

/// Splits terminal input into APC replies. Assumes raw mode.
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

    /// Waits until one complete APC reply arrives, a non-APC byte shows up, or
    /// the deadline passes.
    public func next(timeout: TimeInterval) -> TerminalEvent {
        let deadline = monotonicNow() + timeout

        while true {
            // Drain whatever the previous read left over first.
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
            // An escape sequence that is not an APC, e.g. an arrow key.
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
