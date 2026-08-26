import Foundation
import Testing

@testable import SaverCore

/// A connected socket pair. The code under test gets one end and the test
/// pretends to be the terminal on the other.
struct TestSocketPair {
    let local: Int32
    let remote: Int32

    init() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        local = fds[0]
        remote = fds[1]
    }

    func close() {
        Foundation.close(local)
        Foundation.close(remote)
    }

    func sendFromTerminal(_ text: String) {
        _ = text.withCString { write(remote, $0, strlen($0)) }
    }

    func readAtTerminal(byteCount: Int) -> String {
        var buffer = [UInt8](repeating: 0, count: byteCount)
        let n = buffer.withUnsafeMutableBytes { read(remote, $0.baseAddress, $0.count) }
        guard n > 0 else { return "" }
        return String(decoding: buffer[0..<n], as: UTF8.self)
    }
}

@Suite("terminal replies")
struct ResponseReaderTests {
    @Test("an APC reply is returned without its delimiters")
    func parsesAPCReply() throws {
        let socket = try TestSocketPair()
        defer { socket.close() }

        socket.sendFromTerminal("\u{1b}_Gi=1;OK\u{1b}\\")
        let reader = ResponseReader(fd: socket.local)

        guard case .response(let body) = reader.next(timeout: 1) else {
            Issue.record("expected an APC reply")
            return
        }
        #expect(body == "Gi=1;OK")
    }

    @Test("a reply split across writes is still assembled")
    func handlesSplitReply() throws {
        let socket = try TestSocketPair()
        defer { socket.close() }

        let reader = ResponseReader(fd: socket.local)
        socket.sendFromTerminal("\u{1b}_Gi=1;")
        socket.sendFromTerminal("OK\u{1b}\\")

        guard case .response(let body) = reader.next(timeout: 1) else {
            Issue.record("expected an APC reply")
            return
        }
        #expect(body == "Gi=1;OK")
    }

    @Test("back-to-back replies come out one at a time")
    func handlesConsecutiveReplies() throws {
        let socket = try TestSocketPair()
        defer { socket.close() }

        socket.sendFromTerminal("\u{1b}_Gi=1;OK\u{1b}\\\u{1b}_Gi=2;OK\u{1b}\\")
        let reader = ResponseReader(fd: socket.local)

        guard case .response(let first) = reader.next(timeout: 1),
              case .response(let second) = reader.next(timeout: 1) else {
            Issue.record("expected two APC replies")
            return
        }
        #expect(first == "Gi=1;OK")
        #expect(second == "Gi=2;OK")
    }

    /// A keypress is what stops the screensaver, so it must not be mistaken for
    /// protocol traffic.
    @Test("an ordinary byte reads as user input")
    func plainByteIsUserInput() throws {
        let socket = try TestSocketPair()
        defer { socket.close() }

        socket.sendFromTerminal("q")
        let reader = ResponseReader(fd: socket.local)

        guard case .userInput = reader.next(timeout: 1) else {
            Issue.record("expected user input")
            return
        }
    }

    @Test("an escape sequence that is not an APC reads as user input")
    func arrowKeyIsUserInput() throws {
        let socket = try TestSocketPair()
        defer { socket.close() }

        socket.sendFromTerminal("\u{1b}[A")   // up arrow
        let reader = ResponseReader(fd: socket.local)

        guard case .userInput = reader.next(timeout: 1) else {
            Issue.record("expected user input")
            return
        }
    }

    /// This is what a run inside tmux looks like: the command never arrives, so
    /// nothing ever comes back.
    @Test("silence times out")
    func silenceTimesOut() throws {
        let socket = try TestSocketPair()
        defer { socket.close() }

        let reader = ResponseReader(fd: socket.local)
        guard case .timeout = reader.next(timeout: 0.1) else {
            Issue.record("expected a timeout")
            return
        }
    }

    @Test("an escape inside an APC body does not end it early")
    func escapeInsideBody() throws {
        let socket = try TestSocketPair()
        defer { socket.close() }

        socket.sendFromTerminal("\u{1b}_Gi=1;A\u{1b}B\u{1b}\\")
        let reader = ResponseReader(fd: socket.local)

        guard case .response(let body) = reader.next(timeout: 1) else {
            Issue.record("expected an APC reply")
            return
        }
        #expect(body == "Gi=1;A\u{1b}B")
    }
}

@Suite("CSI 14 t fallback")
struct TerminalSizeTests {
    /// TIOCGWINSZ sometimes reports zero pixels, and this is the fallback that
    /// has to work when it does.
    @Test("the reply is parsed as height then width")
    func parsesReply() throws {
        let socket = try TestSocketPair()
        defer { socket.close() }

        socket.sendFromTerminal("\u{1b}[4;2152;3832t")
        let size = try queryCSI14t(fd: socket.local, timeout: 1)

        #expect(size.width == 3832)
        #expect(size.height == 2152)
    }

    @Test("the query itself is sent")
    func sendsQuery() throws {
        let socket = try TestSocketPair()
        defer { socket.close() }

        socket.sendFromTerminal("\u{1b}[4;10;20t")
        _ = try? queryCSI14t(fd: socket.local, timeout: 1)

        #expect(socket.readAtTerminal(byteCount: 16) == "\u{1b}[14t")
    }

    @Test("no reply is reported as a timeout")
    func noReplyThrows() throws {
        let socket = try TestSocketPair()
        defer { socket.close() }

        #expect(throws: TerminalSizeError.self) {
            _ = try queryCSI14t(fd: socket.local, timeout: 0.1)
        }
    }

    @Test("a reply for something other than CSI 14 t is rejected")
    func wrongReplyThrows() throws {
        let socket = try TestSocketPair()
        defer { socket.close() }

        // CSI 18 t answers with 8, not 4.
        socket.sendFromTerminal("\u{1b}[8;82;319t")
        #expect(throws: TerminalSizeError.self) {
            _ = try queryCSI14t(fd: socket.local, timeout: 1)
        }
    }
}
