import Foundation

/// A path for pushing one frame to the terminal.
///
/// Only the kitty graphics protocol shared memory transfer (a=T, t=s) is
/// implemented, but this is kept separate so it can later be swapped for a=f
/// (pre-baked animation frames) without touching the rest.
public protocol FrameTransport {
    /// Sends a frame. Returns the time spent inside write(2).
    func send(frame: ShmFrame) throws -> TimeInterval
    /// Removes every image and placement the terminal still holds.
    func deleteAll() throws
}

public enum TransportError: Error, CustomStringConvertible {
    case writeFailed(errno: Int32)

    public var description: String {
        switch self {
        case .writeFailed(let code):
            return "write(2) failed: errno=\(code) (\(String(cString: strerror(code))))"
        }
    }
}

/// How much the terminal should talk back.
public enum QuietLevel: Int {
    /// q=0: both OK and errors come back. Reading one response per frame paces
    /// the loop at whatever the terminal can actually consume.
    case verbose = 0
    /// q=1: errors only.
    case errorsOnly = 1
    /// q=2: nothing comes back. Measures the send side's ceiling, not the
    /// terminal's throughput.
    case silent = 2
}

public struct KittySharedMemoryTransport: FrameTransport {
    public let fd: Int32
    public let imageID: UInt32
    public let placementID: UInt32
    public let quiet: QuietLevel

    /// The part that never changes: cursor home plus the APC header.
    private let prefix: [UInt8]
    private let suffix: [UInt8] = Array("\u{1b}\\".utf8)

    public init(
        fd: Int32,
        width: Int,
        height: Int,
        imageID: UInt32 = 1,
        placementID: UInt32 = 1,
        quiet: QuietLevel
    ) {
        self.fd = fd
        self.imageID = imageID
        self.placementID = placementID
        self.quiet = quiet

        // Omitting p makes Ghostty mint a fresh internal placement id on every
        // command (addPlacement in graphics_storage.zig), so placements pile up
        // one per frame. Pinning p makes the (image id, placement id) pair
        // match an existing placement and overwrite it, so a continuous stream
        // of frames still leaves exactly one placement behind.
        // C=1 keeps the cursor where it is.
        let keys = "a=T,f=32,s=\(width),v=\(height),t=s,i=\(imageID),p=\(placementID),q=\(quiet.rawValue),C=1"
        self.prefix = Array("\u{1b}[H\u{1b}_G\(keys);".utf8)
    }

    public func send(frame: ShmFrame) throws -> TimeInterval {
        // The payload is not image data - it is the base64 of the shared memory
        // object's name.
        let payload = Array(Data(frame.name.utf8).base64EncodedString().utf8)
        var bytes = prefix
        bytes.append(contentsOf: payload)
        bytes.append(contentsOf: suffix)

        let start = monotonicNow()
        try bytes.withUnsafeBufferPointer { try writeAll(fd, $0.baseAddress!, $0.count) }
        return monotonicNow() - start
    }

    public func deleteAll() throws {
        let bytes = Array("\u{1b}_Ga=d,d=A\u{1b}\\".utf8)
        try bytes.withUnsafeBufferPointer { try writeAll(fd, $0.baseAddress!, $0.count) }
    }
}

/// Writes every byte, absorbing partial writes and EINTR.
public func writeAll(_ fd: Int32, _ bytes: UnsafePointer<UInt8>, _ count: Int) throws {
    var offset = 0
    while offset < count {
        let n = write(fd, bytes + offset, count - offset)
        if n < 0 {
            if errno == EINTR { continue }
            throw TransportError.writeFailed(errno: errno)
        }
        offset += n
    }
}

/// Monotonic clock, in seconds.
@inline(__always)
public func monotonicNow() -> TimeInterval {
    TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
}
