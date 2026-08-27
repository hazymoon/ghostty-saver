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
    /// whole screensaver on a read that never returned.
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
