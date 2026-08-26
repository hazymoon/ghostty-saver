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
        atexit { TerminalSession.restore() }
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

        if termiosSaved {
            tcsetattr(outputDescriptor, TCSANOW, &originalTermios)
        }
        unlinkTrackedShm()
    }

    private static func write(_ text: String) {
        _ = text.withCString { Darwin.write(outputDescriptor, $0, strlen($0)) }
    }
}
