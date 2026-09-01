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
private var termiosRestored = false

// Written from restore(), which can be a signal handler, so both are built
// here rather than there.
private let deviceAttributesQuery: [UInt8] = Array("\u{1b}[c".utf8)
private let unconfirmedExitNotice: [UInt8] = Array((
    "ghostty-saver: the terminal did not confirm the exit sequence in time; "
    + "if the last frame is still showing, that is why, and anything it says "
    + "from here lands as stray text in whatever reads the terminal next\r\n"
).utf8)

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

        // Opened by the tty's own path rather than as "/dev/tty": that name is
        // a cloning device, and a descriptor from it answers poll with
        // POLLNVAL here, which reads as "there is no reply coming" for every
        // frame. A descriptor that was itself opened as "/dev/tty" - the
        // fallback above - cannot say which terminal is behind it: ttyname()
        // and fstat() both answer "/dev/tty". So the name is taken from
        // whichever standard descriptor is still the terminal, and with
        // output redirected that is usually standard input.
        //
        // A sink was named for output when sinkPath is set, so its tty is not
        // necessarily where replies come back. Read where writing goes then.
        var readFD: Int32 = -1
        if sinkPath == nil {
            for fd in [outputDescriptor, STDIN_FILENO, STDERR_FILENO, STDOUT_FILENO] {
                guard let path = devicePath(of: fd) else { continue }
                readFD = open(path, O_RDONLY | O_NONBLOCK)
                break
            }
        }
        inputDescriptor = readFD >= 0 ? readFD : outputDescriptor
        return true
    }

    /// The path of the terminal device behind a descriptor, or nil when the
    /// descriptor is not a terminal - or is "/dev/tty", the cloning device,
    /// which names no terminal in particular and must not be opened as one.
    static func devicePath(of fd: Int32) -> String? {
        guard isatty(fd) == 1, let name = ttyname(fd) else { return nil }
        let path = String(cString: name)
        return path == "/dev/tty" ? nil : path
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
        _ = termiosRestored
        _ = deviceAttributesQuery
        _ = unconfirmedExitNotice

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
        // A signal can arrive while the first call is still waiting on the
        // terminal below. The sequence has been written by then and must not
        // be written twice, but termios has not been put back, and a process
        // that dies from a signal handler with the terminal in raw mode leaves
        // the shell with no echo. So a second call skips to that part.
        if restored {
            restoreTermios()
            return
        }
        restored = true

        var sequence = "\u{1b}_Ga=d,d=A\u{1b}\\\u{1b}[?25h"
        if altScreenEntered { sequence += "\u{1b}[?1049l" }
        write(sequence)

        // Writing the sequence says nothing about whether the terminal acted
        // on it: a window left showing the last frame could mean the delete
        // was never processed, or that it was and nothing repainted, and from
        // here the two were indistinguishable. So ask the terminal something
        // after it and wait for the answer. The pty is in order, so the
        // answer arriving means everything before it was processed too.
        //
        // The reply to the last frame is often still in flight as well.
        // TCSAFLUSH only discards what has already arrived, so this doubles
        // as letting that land first, otherwise it turns up on the shell
        // prompt as stray text.
        // Five seconds of silence rather than the two this used to allow, and
        // the clock restarts on every byte. The wait ends the moment the
        // answer lands, so the budget is only ever spent on a terminal that
        // has gone quiet, and what it buys is the difference between a slow
        // exit and a reply that arrives after the flush - which is typed into
        // whatever reads the terminal next, a shell prompt or the program
        // that was waiting behind the lock. A terminal that is gone rather
        // than quiet is not waited for at all: poll says so at once.
        if awaitTerminalCatchUp(
            outputFD: outputDescriptor,
            inputFD: inputDescriptor,
            quietFor: 5.0,
            limit: 15.0
        ) == .unanswered {
            unconfirmedExitNotice.withUnsafeBufferPointer {
                _ = Darwin.write(STDERR_FILENO, $0.baseAddress, $0.count)
            }
        }

        restoreTermios()
        unlinkTrackedShm()
    }

    private static func restoreTermios() {
        guard termiosSaved, !termiosRestored else { return }
        termiosRestored = true
        // TCSAFLUSH rather than TCSANOW: whatever is still unread in the
        // input queue - the answer to the query, a reply, a keypress - would
        // otherwise land on the shell prompt as stray text.
        tcsetattr(outputDescriptor, TCSAFLUSH, &originalTermios)
    }

    /// What asking the terminal to catch up found.
    public enum CatchUp: Equatable {
        /// The terminal answered, so everything written before the question
        /// has been processed.
        case confirmed
        /// The deadline passed without an answer.
        case unanswered
        /// Nothing was asked: the reader is a blocking descriptor, and a read
        /// on one of those can park for good.
        case notAsked
    }

    /// Sends a primary device attributes query (`CSI c`) and waits for the
    /// answer (`CSI ? ... c`), reading and discarding whatever precedes it.
    ///
    /// `quietFor` is how long the terminal has to say nothing before it is
    /// given up on, counted from the last byte rather than from the start: a
    /// terminal working through a backlog is replying to what it was sent all
    /// the while, and the answer is behind that. `limit` bounds the whole
    /// wait, for the one shape that would otherwise never end - a terminal
    /// that talks without ever answering.
    ///
    /// Only reads when `inputFD` is non-blocking. The terminal is in raw mode
    /// with VMIN 1 while the screensaver runs, where a read that finds nothing
    /// waits for as long as the terminal takes to say something - and it can
    /// be nothing, if another reader on the same tty takes the byte between
    /// the poll and the read. A 20 second run was once found parked here 23
    /// minutes later, with its last frame up and no way out but a keypress.
    /// The reader opened by openOutput() is non-blocking; the fallback, when
    /// that open failed, is the shell's own descriptor, which is not, and
    /// which this process must not flip. On that path nothing is asked and
    /// this only waits, briefly, for whatever is already on its way.
    ///
    /// Safe to call from a signal handler: nothing here allocates.
    static func awaitTerminalCatchUp(
        outputFD: Int32,
        inputFD: Int32,
        quietFor: TimeInterval,
        limit: TimeInterval
    ) -> CatchUp {
        let flags = fcntl(inputFD, F_GETFL)
        guard flags >= 0, flags & O_NONBLOCK != 0 else {
            awaitPendingInput(fd: inputFD)
            return .notAsked
        }

        deviceAttributesQuery.withUnsafeBufferPointer {
            _ = Darwin.write(outputFD, $0.baseAddress, $0.count)
        }

        var deadline = monotonicNow() + quietFor
        let ceiling = monotonicNow() + limit
        // ESC [ ? ... c, scanned a byte at a time. Nothing else that can be
        // queued ahead of the answer - an APC reply, a keypress, an arrow
        // key's ESC [ A - contains "ESC [ ?".
        var stage = 0
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 256) { buffer -> CatchUp in
            while true {
                let remainingMs = Int32((min(deadline, ceiling) - monotonicNow()) * 1000)
                if remainingMs <= 0 { return .unanswered }

                var pfd = pollfd(fd: inputFD, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, remainingMs)
                if ready == 0 { return .unanswered }
                if ready < 0 {
                    if errno == EINTR { continue }
                    return .unanswered
                }
                if pfd.revents & Int16(POLLIN) == 0 { return .unanswered }

                let n = read(inputFD, buffer.baseAddress, buffer.count)
                if n <= 0 {
                    if n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
                    return .unanswered
                }
                // Something arrived, so the terminal has not gone away and the
                // answer is still coming. Start the silence over.
                deadline = monotonicNow() + quietFor
                for byte in buffer[0..<n] {
                    switch (stage, byte) {
                    case (_, 0x1b): stage = 1
                    case (1, UInt8(ascii: "[")): stage = 2
                    case (2, UInt8(ascii: "?")): stage = 3
                    case (3, UInt8(ascii: "c")): return .confirmed
                    case (3, _): break
                    default: stage = 0
                    }
                }
            }
        }
    }

    /// Waits, briefly, for whatever the terminal is still sending to arrive.
    ///
    /// Nothing is read. The flush in restore() takes the whole input queue at
    /// once, so all this has to do is let the queue fill first. This is the
    /// path for a blocking reader, where a read is the one thing that must
    /// not happen: in raw mode with VMIN 1 a read that finds nothing behind
    /// it waits indefinitely, and this runs after the render loop, so a read
    /// that parks stops the screensaver with its last frame up. poll takes a
    /// timeout and the loop is counted, so this returns whatever the terminal
    /// is doing, and poll is safe to call from the signal handler this can
    /// run in.
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
