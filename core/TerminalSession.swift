import Foundation

// Owns every change made to the terminal and the corresponding restore.
//
// restore() is reachable from a signal handler, so the state lives in
// file-scope globals that prepare() touches up front, keeping lazy
// initialization out of the handler.

private var outputDescriptor: Int32 = STDOUT_FILENO
// Reading has its own descriptor, opened non-blocking. The terminal is in raw
// mode with VMIN 1 while the screensaver runs, where a read that finds nothing
// waits for as long as the terminal takes to say something - and it can be
// nothing, if another reader on the same tty takes the byte between the poll
// and the read. A stuck instance of this program is exactly such a reader, so
// one hang on a tty makes the next one likelier.
//
// It matters that this is a second open() of /dev/tty rather than the same
// descriptor or a dup of it: O_NONBLOCK belongs to the open file description,
// and the one behind standard output is the shell's. Setting the flag there
// would leave it set for the shell if this process is killed outright.
private var inputDescriptor: Int32 = STDIN_FILENO
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

    /// Where replies and keypresses are read from. Non-blocking, so nothing
    /// that reads it can be left waiting on a terminal that has gone quiet.
    public static var inputFD: Int32 { inputDescriptor }

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
        guard isatty(outputDescriptor) == 1 else { return false }

        // A sink was named for output, so its tty is not necessarily the one
        // replies come back on. Read where writing goes in that case.
        let readFD = sinkPath == nil ? open("/dev/tty", O_RDONLY | O_NONBLOCK) : -1
        inputDescriptor = readFD >= 0 ? readFD : outputDescriptor
        return true
    }

    /// Allocates shared memory tracking and installs signal and atexit
    /// handlers. Call before touching the terminal.
    public static func prepare() {
        prepareShmTracking()
        // Force the globals to initialize now rather than inside a handler.
        _ = outputDescriptor
        _ = inputDescriptor
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
        awaitPendingInput(fd: inputDescriptor)

        if termiosSaved {
            // TCSAFLUSH rather than TCSANOW: the reply to the last frame is
            // usually still sitting unread in the input queue, and anything
            // left there lands on the shell prompt as stray text.
            tcsetattr(outputDescriptor, TCSAFLUSH, &originalTermios)
        }
        unlinkTrackedShm()
    }

    /// Waits, briefly, for whatever the terminal is still sending to arrive.
    ///
    /// Nothing is read. The flush in restore() takes the whole input queue at
    /// once, so all this has to do is let the queue fill first.
    ///
    /// Reading it instead is what this did before, and a read is the one thing
    /// that must not happen here. The terminal is still in raw mode with
    /// VMIN 1, where a read that finds nothing behind it waits indefinitely -
    /// and this runs after the render loop, so a read that parks stops the
    /// screensaver with its last frame up, nothing printed, and no way out but
    /// a keypress. A 20 second run was found sitting here 23 minutes later.
    /// poll takes a timeout and the loop is counted, so this returns whatever
    /// the terminal is doing, and poll is safe to call from the signal handler
    /// this can run in.
    static func awaitPendingInput(fd: Int32) {
        for _ in 0..<20 {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&pfd, 1, 10) > 0 && pfd.revents & Int16(POLLIN) != 0 {
                // Something is queued. The rest of the reply is right behind
                // it and the flush wants the lot, so give it a moment.
                _ = poll(nil, 0, 20)
                return
            }
        }
    }

    private static func write(_ text: String) {
        _ = text.withCString { Darwin.write(outputDescriptor, $0, strlen($0)) }
    }
}
