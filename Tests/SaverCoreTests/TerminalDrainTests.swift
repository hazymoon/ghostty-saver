import Foundation
import Testing

@testable import SaverCore

@Suite("waiting for the terminal's last reply")
struct TerminalDrainTests {
    /// A pty whose slave is in raw mode, so a test can put bytes in front of a
    /// reader the way a terminal does.
    private struct Pty {
        let master: Int32
        let slave: Int32

        init?() {
            let master = posix_openpt(O_RDWR | O_NOCTTY)
            guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0,
                  let name = ptsname(master) else { return nil }
            let slave = open(name, O_RDWR | O_NOCTTY)
            guard slave >= 0 else { Darwin.close(master); return nil }

            var raw = termios()
            guard tcgetattr(slave, &raw) == 0 else {
                Darwin.close(master); Darwin.close(slave); return nil
            }
            cfmakeraw(&raw)
            raw.c_cc.16 = 1   // VMIN
            raw.c_cc.17 = 0   // VTIME
            guard tcsetattr(slave, TCSANOW, &raw) == 0 else {
                Darwin.close(master); Darwin.close(slave); return nil
            }

            self.master = master
            self.slave = slave
        }

        func send(_ text: String) {
            let bytes = Array(text.utf8)
            _ = bytes.withUnsafeBufferPointer { write(master, $0.baseAddress, $0.count) }
        }

        var hasQueuedInput: Bool {
            var pfd = pollfd(fd: slave, events: Int16(POLLIN), revents: 0)
            return poll(&pfd, 1, 500) == 1 && pfd.revents & Int16(POLLIN) != 0
        }

        func close() {
            Darwin.close(master)
            Darwin.close(slave)
        }
    }

    /// Runs the wait on a thread, so a call that never comes back fails the
    /// test rather than hanging the suite. The thread is left behind if that
    /// happens, which is the price of catching it at all.
    private func completes(fd: Int32, within seconds: Double) -> Bool {
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            TerminalSession.awaitPendingInput(fd: fd)
            done.signal()
        }
        return done.wait(timeout: .now() + seconds) == .success
    }

    /// The reply must still be in the queue afterwards: restore() discards it
    /// with TCSAFLUSH, and reading it here instead is what used to park the
    /// whole screensaver on a read that never returned. This is now the path
    /// for a blocking reader only - a non-blocking one is read, and asked to
    /// confirm, by awaitTerminalCatchUp - but on a blocking one the rule
    /// stands.
    @Test("it leaves the reply for the flush to discard")
    func leavesTheQueueAlone() throws {
        let pty = try #require(Pty())
        defer { pty.close() }

        pty.send("\u{1b}_Gi=1;OK\u{1b}\\")
        #expect(pty.hasQueuedInput, "the reply should reach the queue")

        #expect(completes(fd: pty.slave, within: 2.0))
        #expect(pty.hasQueuedInput, "the reply should still be there to flush")
    }

    /// A terminal that answers nothing must not hold the exit path open.
    @Test("it gives up when nothing arrives")
    func givesUp() throws {
        let pty = try #require(Pty())
        defer { pty.close() }

        let start = monotonicNow()
        #expect(completes(fd: pty.slave, within: 2.0))
        #expect(monotonicNow() - start < 1.0)
    }

    /// A poll that reports something other than readable - a closed or errored
    /// descriptor - is not a byte to wait on either.
    @Test("it gives up on a dead descriptor")
    func deadDescriptor() throws {
        let pty = try #require(Pty())
        pty.close()

        #expect(completes(fd: pty.slave, within: 2.0))
    }
}

/// The state that hung a real run: a byte arrives, poll reports it, and by the
/// time the read happens another reader on the same tty has taken it. A stuck
/// instance of this program is such a reader, which is how one hang made the
/// next one likelier.
@Suite("reading a tty another reader is on")
struct ContendedReadTests {
    /// Runs one round: a reader parked on the tty, a byte written while the
    /// subject is waiting for it. Returns whether the subject came back.
    private func subjectReturns(startCompetitor: Bool) -> Bool {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0,
              let name = ptsname(master) else { return false }
        let path = String(cString: name)
        let slave = open(path, O_RDWR | O_NOCTTY)
        guard slave >= 0 else { close(master); return false }

        var raw = termios()
        _ = tcgetattr(slave, &raw)
        cfmakeraw(&raw)
        raw.c_cc.16 = 1   // VMIN
        raw.c_cc.17 = 0   // VTIME
        _ = tcsetattr(slave, TCSANOW, &raw)

        // The subject gets its own descriptor, the way the screensaver's
        // reader does, so the competitor below is a separate reader rather
        // than the same one.
        let subjectFD = open(path, O_RDONLY | O_NOCTTY)
        guard subjectFD >= 0 else { close(master); close(slave); return false }

        if startCompetitor {
            Thread.detachNewThread {
                var byte: UInt8 = 0
                _ = read(slave, &byte, 1)
            }
            // Let it reach the read before anything is sent.
            Thread.sleep(forTimeInterval: 0.05)
        }

        let reader = ResponseReader(fd: subjectFD)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = reader.next(timeout: 0.2)
            done.signal()
        }

        Thread.sleep(forTimeInterval: 0.01)
        var byte: UInt8 = 0x1b
        _ = write(master, &byte, 1)

        let returned = done.wait(timeout: .now() + 3.0) == .success
        close(master)
        close(slave)
        close(subjectFD)
        return returned
    }

    /// A blocking reader parks on the first round here, near enough every
    /// time, but the state is a race and a round is cheap.
    @Test("it comes back even when another reader takes the byte")
    func survivesContention() {
        for round in 1...10 {
            #expect(subjectReturns(startCompetitor: true), "round \(round) never came back")
        }
    }

    @Test("it comes back with the tty to itself")
    func uncontended() {
        #expect(subjectReturns(startCompetitor: false))
    }
}

/// The exit path used to write its last bytes and leave. Whether the terminal
/// ever acted on them was unknowable from this side, which is what made a
/// window left showing the last frame impossible to attribute. Now it asks
/// the terminal a question after them and waits for the answer: a terminal
/// processes what it is sent in order, so the answer arriving means the delete
/// and the alt-screen exit were processed before it.
@Suite("confirming the terminal processed the exit sequence")
struct TerminalCatchUpTests {
    /// A pty with the reader's descriptor opened the way the screensaver opens
    /// it: a second open of the device, non-blocking, separate from the one
    /// that writes.
    private struct Pty {
        let master: Int32
        let slave: Int32
        let reader: Int32

        init?(nonBlockingReader: Bool = true) {
            let master = posix_openpt(O_RDWR | O_NOCTTY)
            guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0,
                  let name = ptsname(master) else { return nil }
            let path = String(cString: name)
            let slave = open(path, O_RDWR | O_NOCTTY)
            guard slave >= 0 else { Darwin.close(master); return nil }

            var raw = termios()
            guard tcgetattr(slave, &raw) == 0 else {
                Darwin.close(master); Darwin.close(slave); return nil
            }
            cfmakeraw(&raw)
            raw.c_cc.16 = 1   // VMIN
            raw.c_cc.17 = 0   // VTIME
            guard tcsetattr(slave, TCSANOW, &raw) == 0 else {
                Darwin.close(master); Darwin.close(slave); return nil
            }

            let reader = open(path, O_RDONLY | O_NOCTTY | (nonBlockingReader ? O_NONBLOCK : 0))
            guard reader >= 0 else { Darwin.close(master); Darwin.close(slave); return nil }

            self.master = master
            self.slave = slave
            self.reader = reader
        }

        func send(_ text: String) {
            let bytes = Array(text.utf8)
            _ = bytes.withUnsafeBufferPointer { write(master, $0.baseAddress, $0.count) }
        }

        /// What the screensaver wrote, as the terminal would see it.
        func receive(within seconds: Double) -> String {
            var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, Int32(seconds * 1000)) == 1 else { return "" }
            var buffer = [UInt8](repeating: 0, count: 256)
            let n = buffer.withUnsafeMutableBytes { read(master, $0.baseAddress, $0.count) }
            guard n > 0 else { return "" }
            return String(decoding: buffer[0..<n], as: UTF8.self)
        }

        /// Waits for the query the exit path sends. False when nothing came,
        /// which is the terminal side of a test that is already failing.
        private func awaitQuery() -> Bool {
            var seen = ""
            while !seen.contains("\u{1b}[c") {
                let chunk = receive(within: 1.0)
                if chunk.isEmpty { return false }
                seen += chunk
            }
            return true
        }

        /// Plays the terminal: answers the primary DA query when it shows up,
        /// in as many writes as asked for, so the answer can straddle reads.
        func answerDeviceAttributes(after preamble: String = "", inPieces pieces: Int = 1) {
            Thread.detachNewThread {
                guard awaitQuery() else { return }
                let answer = Array((preamble + "\u{1b}[?62;22c").utf8)
                let size = max(1, answer.count / pieces)
                var offset = 0
                while offset < answer.count {
                    let end = min(answer.count, offset + size)
                    send(String(decoding: answer[offset..<end], as: UTF8.self))
                    offset = end
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
        }

        /// Plays a terminal that is behind rather than gone: it keeps replying
        /// to what it was sent earlier while it works through the backlog, and
        /// only answers the query once it has caught up.
        func answerDeviceAttributes(afterChattering rounds: Int, every interval: TimeInterval) {
            Thread.detachNewThread {
                guard awaitQuery() else { return }
                for _ in 0..<rounds {
                    Thread.sleep(forTimeInterval: interval)
                    send("\u{1b}_Gi=1,p=1;OK\u{1b}\\")
                }
                send("\u{1b}[?62;22;52c")
            }
        }

        /// Plays a terminal that talks without ever answering, which is the
        /// one shape a wait that extends on every byte could sit in forever.
        /// The rounds are counted so the thread stops on its own once the
        /// test that started it has gone.
        func chatterWithoutAnswering(rounds: Int = 400, every interval: TimeInterval = 0.05) {
            Thread.detachNewThread {
                guard awaitQuery() else { return }
                for _ in 0..<rounds {
                    Thread.sleep(forTimeInterval: interval)
                    send("\u{1b}_Gi=1,p=1;OK\u{1b}\\")
                }
            }
        }

        var readerHasQueuedInput: Bool {
            var pfd = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
            return poll(&pfd, 1, 200) == 1 && pfd.revents & Int16(POLLIN) != 0
        }

        func close() {
            Darwin.close(master)
            Darwin.close(slave)
            Darwin.close(reader)
        }
    }

    private func runCatchUp(
        _ pty: Pty, quietFor: TimeInterval, limit: TimeInterval = 5.0
    ) -> TerminalSession.CatchUp? {
        let done = DispatchSemaphore(value: 0)
        var outcome: TerminalSession.CatchUp?
        Thread.detachNewThread {
            outcome = TerminalSession.awaitTerminalCatchUp(
                outputFD: pty.slave, inputFD: pty.reader, quietFor: quietFor, limit: limit
            )
            done.signal()
        }
        guard done.wait(timeout: .now() + limit + 2.0) == .success else { return nil }
        return outcome
    }

    @Test("a terminal that answers is confirmed")
    func confirmed() throws {
        let pty = try #require(Pty())
        defer { pty.close() }

        pty.answerDeviceAttributes()
        let start = monotonicNow()
        #expect(runCatchUp(pty, quietFor: 2.0) == .confirmed)
        #expect(monotonicNow() - start < 1.0, "it should return as soon as the answer lands")
    }

    /// What is actually in the queue at exit: the reply to the last frame,
    /// possibly the keypress that ended the run, and only then the answer.
    @Test("the answer is found behind the last frame's reply and a keypress")
    func confirmedBehindStaleInput() throws {
        let pty = try #require(Pty())
        defer { pty.close() }

        pty.answerDeviceAttributes(after: "\u{1b}_Gi=1;OK\u{1b}\\q\u{1b}[A")
        #expect(runCatchUp(pty, quietFor: 2.0) == .confirmed)
    }

    @Test("an answer that arrives in pieces is still found")
    func confirmedAcrossReads() throws {
        let pty = try #require(Pty())
        defer { pty.close() }

        pty.answerDeviceAttributes(after: "\u{1b}_Gi=1;OK\u{1b}\\", inPieces: 7)
        #expect(runCatchUp(pty, quietFor: 2.0) == .confirmed)
    }

    /// A terminal that is behind is not a terminal that has gone away: it is
    /// still replying to what it was sent, and the answer is behind that.
    /// Giving up in the middle leaves the rest - the last frame's reply, then
    /// the answer - to arrive after the flush, where it is typed into whatever
    /// reads the terminal next.
    @Test("a terminal that is behind is followed until it answers")
    func confirmedAfterABacklog() throws {
        let pty = try #require(Pty())
        defer { pty.close() }

        pty.answerDeviceAttributes(afterChattering: 9, every: 0.1)
        #expect(runCatchUp(pty, quietFor: 0.3) == .confirmed)
    }

    @Test("a terminal that never answers is given up on within the deadline")
    func unanswered() throws {
        let pty = try #require(Pty())
        defer { pty.close() }

        let start = monotonicNow()
        #expect(runCatchUp(pty, quietFor: 0.3) == .unanswered)
        // The deadline is kept to the millisecond poll() takes, so the wait
        // can come back a fraction of one early.
        let took = monotonicNow() - start
        #expect(took >= 0.29 && took < 1.0, "took \(took) s")
    }

    /// The silence restarting on every byte still has to end somewhere. A
    /// terminal that talks without ever answering is the one shape that would
    /// otherwise hold the exit path open for as long as it kept talking.
    @Test("a terminal that talks without answering is given up on at the limit")
    func unansweredWhileTalking() throws {
        let pty = try #require(Pty())
        defer { pty.close() }

        pty.chatterWithoutAnswering()
        let start = monotonicNow()
        #expect(runCatchUp(pty, quietFor: 0.3, limit: 0.6) == .unanswered)
        let took = monotonicNow() - start
        #expect(took >= 0.59 && took < 1.5, "took \(took) s")
    }

    /// The fallback when the reader is the shell's own blocking descriptor:
    /// nothing may be read there, so nothing is asked either, and the bytes
    /// already queued are left for the flush to discard, as before.
    @Test("a blocking reader is not read from, or asked anything")
    func blockingReaderIsLeftAlone() throws {
        let pty = try #require(Pty(nonBlockingReader: false))
        defer { pty.close() }

        pty.send("\u{1b}_Gi=1;OK\u{1b}\\")
        #expect(pty.readerHasQueuedInput)

        #expect(runCatchUp(pty, quietFor: 1.0) == .notAsked)
        #expect(pty.readerHasQueuedInput, "the reply should still be there to flush")
        #expect(pty.receive(within: 0.2).isEmpty, "no query should have reached the terminal")
    }
}

/// The reader is a second open of the terminal by its own device name. When
/// output was opened as "/dev/tty", ttyname() hands that name straight back,
/// and a descriptor from it answers poll with POLLNVAL for every frame - so
/// that name is the one answer this must never give.
@Suite("naming the terminal's device")
struct DevicePathTests {
    @Test("a pty slave is named by its own path")
    func ptySlaveIsNamed() throws {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        try #require(master >= 0 && grantpt(master) == 0 && unlockpt(master) == 0)
        defer { close(master) }
        let path = String(cString: try #require(ptsname(master)))
        let slave = open(path, O_RDWR | O_NOCTTY)
        try #require(slave >= 0)
        defer { close(slave) }

        #expect(TerminalSession.devicePath(of: slave) == path)
    }

    /// Only meaningful with a controlling terminal, which `swift test` under
    /// an IDE or CI may not have; then there is nothing to open and nothing
    /// to check.
    @Test("the cloning device is not a name")
    func cloningDeviceIsNotAName() throws {
        let fd = open("/dev/tty", O_RDWR)
        guard fd >= 0 else { return }
        defer { close(fd) }
        #expect(TerminalSession.devicePath(of: fd) == nil)
    }

    @Test("a descriptor that is not a terminal has no name")
    func nonTerminalHasNoName() throws {
        var fds: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        #expect(TerminalSession.devicePath(of: fds[0]) == nil)
    }
}
