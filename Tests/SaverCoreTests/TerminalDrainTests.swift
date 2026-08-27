import Foundation
import Testing

@testable import SaverCore

@Suite("terminal drain")
struct TerminalDrainTests {
    /// A pty whose slave is in raw mode, so a test can put bytes in front of a
    /// reader the way a terminal does.
    private struct Pty {
        let master: Int32
        let slave: Int32

        init?(minimumRead: cc_t) {
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
            raw.c_cc.16 = minimumRead   // VMIN
            raw.c_cc.17 = 0             // VTIME
            guard tcsetattr(slave, TCSANOW, &raw) == 0 else {
                Darwin.close(master); Darwin.close(slave); return nil
            }

            self.master = master
            self.slave = slave
        }

        func close() {
            Darwin.close(master)
            Darwin.close(slave)
        }
    }

    /// Runs the drain on a thread so a hang fails the test instead of hanging
    /// the suite. The thread is left behind if it never returns, which is the
    /// price of catching a read that never comes back.
    private func drainCompletes(fd: Int32, within seconds: Double) -> Bool {
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            TerminalSession.drainBriefly(fd: fd)
            done.signal()
        }
        return done.wait(timeout: .now() + seconds) == .success
    }

    /// The terminal's reply to the last frame is what the drain is for: it has
    /// to be taken out of the queue before termios is restored, or it lands on
    /// the shell prompt.
    @Test("it takes what the terminal sent")
    func drainsPendingBytes() throws {
        let pty = try #require(Pty(minimumRead: 1))
        defer { pty.close() }

        let reply = Array("\u{1b}_Gi=1;OK\u{1b}\\".utf8)
        _ = reply.withUnsafeBufferPointer { write(pty.master, $0.baseAddress, $0.count) }

        #expect(drainCompletes(fd: pty.slave, within: 2.0))

        var pfd = pollfd(fd: pty.slave, events: Int16(POLLIN), revents: 0)
        #expect(poll(&pfd, 1, 0) == 0, "the reply should be gone from the queue")
    }

    /// Nothing queued: the drain has to give up on its own rather than sit on
    /// a read. It runs after the render loop, so a read that never returns
    /// stops the screensaver with the last frame up and nothing printed.
    @Test("it gives up when the terminal sent nothing")
    func drainsNothingPromptly() throws {
        let pty = try #require(Pty(minimumRead: 1))
        defer { pty.close() }

        #expect(drainCompletes(fd: pty.slave, within: 2.0))
    }

    /// A poll that reports something other than readable - a closed or errored
    /// descriptor - must not be taken as a byte to read.
    @Test("it does not treat a dead descriptor as something to read")
    func deadDescriptor() throws {
        let pty = try #require(Pty(minimumRead: 1))
        pty.close()

        #expect(drainCompletes(fd: pty.slave, within: 2.0))
    }
}
