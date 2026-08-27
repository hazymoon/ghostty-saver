import Foundation

// Owns every change made to the terminal and the corresponding restore.
//
// restore() is reachable from a signal handler, so the state lives in
// file-scope globals that prepare() touches up front, keeping lazy
// initialization out of the handler.

private var outputDescriptor: Int32 = STDOUT_FILENO
private var originalTermios = termios()
private var termiosSaved = false
private var altScreenEntered = false
private var restored = false

// Set from a signal handler, so it has to be a type the handler may touch.
private var resizeRequested: sig_atomic_t = 0

/// Raises the resize flag. The SIGWINCH handler calls this, and it is the only
/// work the handler does - re-measuring the terminal and reallocating buffers
/// is not safe from inside a handler.
func markResizeRequested() {
    resizeRequested = 1
}

public enum TerminalSession {
    /// Where terminal output goes.
    public static var outputFD: Int32 { outputDescriptor }

    /// Picks and opens the output. Returns whether it is a tty.
    /// Prefers sinkPath, then standard output, then /dev/tty when standard
    /// output has been redirected.
    @discardableResult
    public static func openOutput(sinkPath: String?) -> Bool {
        if let sinkPath {
            let fd = open(sinkPath, O_WRONLY)
            if fd >= 0 { outputDescriptor = fd }
        } else if isatty(STDOUT_FILENO) == 1 {
            outputDescriptor = STDOUT_FILENO
        } else {
            let fd = open("/dev/tty", O_RDWR)
            outputDescriptor = fd >= 0 ? fd : STDOUT_FILENO
        }
        return isatty(outputDescriptor) == 1
    }

    /// Allocates shared memory tracking and installs signal and atexit
    /// handlers. Call before touching the terminal.
    public static func prepare() {
        prepareShmTracking()
        // Force the globals to initialize now rather than inside a handler.
        _ = outputDescriptor
        _ = termiosSaved
        _ = altScreenEntered
        _ = restored

        let handler: @convention(c) (Int32) -> Void = { signalNumber in
            TerminalSession.restore()
            signal(signalNumber, SIG_DFL)
            raise(signalNumber)
        }
        signal(SIGINT, handler)
        signal(SIGTERM, handler)
        signal(SIGHUP, handler)

        installResizeHandler()
        atexit { TerminalSession.restore() }
    }

    /// Installs the SIGWINCH handler on its own, without the rest of prepare().
    public static func installResizeHandler() {
        signal(SIGWINCH, { _ in markResizeRequested() } as @convention(c) (Int32) -> Void)
    }

    /// Whether the terminal has been resized since this was last asked.
    /// Clears the flag, so a caller acts on each resize exactly once.
    public static func takeResizeRequest() -> Bool {
        guard resizeRequested != 0 else { return false }
        resizeRequested = 0
        return true
    }

    /// Reads and throws away whatever the terminal has already sent.
    ///
    /// Exiting on a keypress leaves the last frame's reply unread. restore()
    /// flushes the queue as it restores termios, but a reply that has not
    /// arrived yet would survive that, so the normal exit path drains first.
    /// Not for use from a signal handler.
    public static func discardPendingInput(for duration: TimeInterval = 0.05) {
        // The deadline bounds the loop, not a read inside it: the same
        // unreadable-but-polled state that drainBriefly guards against would
        // park here for good, one line before the exit path reaches it.
        let flags = fcntl(outputDescriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(outputDescriptor, F_SETFL, flags | O_NONBLOCK) }
        defer { if flags >= 0 { _ = fcntl(outputDescriptor, F_SETFL, flags) } }

        var chunk = [UInt8](repeating: 0, count: 256)
        let deadline = monotonicNow() + duration
        while monotonicNow() < deadline {
            var pfd = pollfd(fd: outputDescriptor, events: Int16(POLLIN), revents: 0)
            let remainingMs = Int32(max(0, (deadline - monotonicNow()) * 1000))
            if poll(&pfd, 1, remainingMs) <= 0 || pfd.revents & Int16(POLLIN) == 0 { break }
            let n = chunk.withUnsafeMutableBytes { read(outputDescriptor, $0.baseAddress, $0.count) }
            if n <= 0 { break }
        }
    }

    /// Enters raw mode, configured to return as soon as one byte is available.
    public static func enterRawMode() {
        var raw = termios()
        guard tcgetattr(outputDescriptor, &raw) == 0 else { return }
        originalTermios = raw
        termiosSaved = true
        cfmakeraw(&raw)
        raw.c_cc.16 = 1   // VMIN
        raw.c_cc.17 = 0   // VTIME
        tcsetattr(outputDescriptor, TCSANOW, &raw)
    }

    public static func enterAltScreen() {
        write("\u{1b}[?1049h")
        altScreenEntered = true
    }

    public static func hideCursor() {
        write("\u{1b}[?25l")
    }

    /// Deletes images, shows the cursor, leaves the alternate screen, restores
    /// termios and reclaims shared memory. Idempotent.
    public static func restore() {
        if restored { return }
        restored = true

        var sequence = "\u{1b}_Ga=d,d=A\u{1b}\\\u{1b}[?25h"
        if altScreenEntered { sequence += "\u{1b}[?1049l" }
        write(sequence)

        // The reply to the last frame is often still in flight. TCSAFLUSH only
        // discards what has already arrived, so give it a moment to land first,
        // otherwise it turns up on the shell prompt as stray text.
        // poll and read are both async-signal-safe, so this is reachable from
        // the signal handler.
        drainBriefly(fd: outputDescriptor)

        if termiosSaved {
            // TCSAFLUSH rather than TCSANOW: the reply to the last frame is
            // usually still sitting unread in the input queue, and anything
            // left there lands on the shell prompt as stray text.
            tcsetattr(outputDescriptor, TCSAFLUSH, &originalTermios)
        }
        unlinkTrackedShm()
    }

    /// Reads and discards for a bounded number of short polls. Deliberately
    /// counts iterations rather than consulting a clock, to keep the work
    /// inside a signal handler to calls that are safe there.
    ///
    /// Nothing here may block. The terminal is still in raw mode with VMIN 1,
    /// where a read with nothing behind it waits indefinitely, and this runs
    /// after the render loop has finished - a read that parks stops the
    /// screensaver with its last frame up, no message, and no way out but a
    /// keypress. poll answering at all is not the same as poll answering
    /// "readable": POLLERR and POLLNVAL arrive as a positive return too, and a
    /// byte can go somewhere else between the poll and the read. So the events
    /// are checked, and the descriptor is non-blocking for the duration in
    /// case something gets past that. fcntl is safe to call from the signal
    /// handler this can run in.
    static func drainBriefly(fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        defer { if flags >= 0 { _ = fcntl(fd, F_SETFL, flags) } }

        var chunk = [UInt8](repeating: 0, count: 256)
        var idlePolls = 0
        for _ in 0..<20 {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&pfd, 1, 10) <= 0 || pfd.revents & Int16(POLLIN) == 0 {
                idlePolls += 1
                if idlePolls >= 2 { return }
                continue
            }
            idlePolls = 0
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return }
        }
    }

    private static func write(_ text: String) {
        _ = text.withCString { Darwin.write(outputDescriptor, $0, strlen($0)) }
    }
}
