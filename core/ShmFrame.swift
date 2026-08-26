import Foundation
import CShim

/// macOS caps POSIX shared memory names at 31 bytes including the leading '/'
/// (PSHMNAMLEN). This is stricter than Linux, so names must stay short.
public let shmNameMaxBytes = 31

// MARK: - Tracking unreclaimed segments

// The terminal calls shm_unlink itself once it has read a segment, so tracking
// is normally unnecessary. But a frame the terminal never reads - because t=s
// is unsupported, the command errored, or the terminal fell behind - leaves a
// segment that nobody unlinks until reboot. A ring keeps that leak bounded.
//
// The signal handler touches this, so it lives in a raw C buffer rather than a
// Swift Array, and prepareShmTracking() allocates it up front so no lazy
// initialization runs inside the handler.

private let shmSlotCount = 16
private let shmSlotBytes = 32
private var shmSlots: UnsafeMutablePointer<CChar>?
private var shmSlotCursor = 0

/// Must be called before installing signal handlers.
public func prepareShmTracking() {
    guard shmSlots == nil else { return }
    let total = shmSlotCount * shmSlotBytes
    let p = UnsafeMutablePointer<CChar>.allocate(capacity: total)
    p.initialize(repeating: 0, count: total)
    shmSlots = p
}

/// Unlinks every tracked segment. Harmless if the terminal already unlinked one
/// (shm_unlink just returns ENOENT).
public func unlinkTrackedShm() {
    guard let slots = shmSlots else { return }
    for i in 0..<shmSlotCount {
        let p = slots + i * shmSlotBytes
        if p.pointee != 0 {
            _ = shm_unlink(p)
            p.pointee = 0
        }
    }
}

private func trackShm(_ name: UnsafePointer<CChar>) {
    guard let slots = shmSlots else { return }
    let p = slots + shmSlotCursor * shmSlotBytes
    // A name still present shmSlotCount frames later was never read by the
    // terminal, so reclaim it.
    if p.pointee != 0 { _ = shm_unlink(p) }
    _ = strlcpy(p, name, shmSlotBytes)
    shmSlotCursor = (shmSlotCursor + 1) % shmSlotCount
}

// MARK: - Frames

public enum ShmFrameError: Error, CustomStringConvertible {
    case nameTooLong(String)
    case openFailed(name: String, errno: Int32)
    case truncateFailed(errno: Int32)
    case mapFailed(errno: Int32)

    public var description: String {
        switch self {
        case .nameTooLong(let name):
            return "shared memory name exceeds \(shmNameMaxBytes) bytes: \(name)"
        case .openFailed(let name, let code):
            return "shm_open(\(name)) failed: errno=\(code) (\(String(cString: strerror(code))))"
        case .truncateFailed(let code):
            return "ftruncate failed: errno=\(code) (\(String(cString: strerror(code))))"
        case .mapFailed(let code):
            return "mmap failed: errno=\(code) (\(String(cString: strerror(code))))"
        }
    }
}

/// One frame's worth of shared memory.
///
/// The terminal unlinks a segment once it has read it, so every frame needs a
/// freshly created one.
public struct ShmFrame {
    public let name: String
    public let fd: Int32
    public let base: UnsafeMutableRawPointer
    /// Length passed to mmap, rounded up to a page boundary.
    public let mappedBytes: Int
    /// Length that is meaningful as image data (width * height * 4).
    public let payloadBytes: Int

    /// Creates a segment under the given name. ftruncate rounds up to a page.
    public static func create(name: String, payloadBytes: Int) throws -> ShmFrame {
        guard name.utf8.count <= shmNameMaxBytes else {
            throw ShmFrameError.nameTooLong(name)
        }

        let pageSize = Int(getpagesize())
        let mappedBytes = (payloadBytes + pageSize - 1) / pageSize * pageSize

        let fd: Int32 = name.withCString { cname in
            let fd = gs_shm_create(cname)
            if fd >= 0 { trackShm(cname) }
            return fd
        }
        guard fd >= 0 else {
            throw ShmFrameError.openFailed(name: name, errno: errno)
        }

        guard ftruncate(fd, off_t(mappedBytes)) == 0 else {
            let code = errno
            close(fd)
            name.withCString { _ = shm_unlink($0) }
            throw ShmFrameError.truncateFailed(errno: code)
        }

        let base = mmap(nil, mappedBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard let base, base != MAP_FAILED else {
            let code = errno
            close(fd)
            name.withCString { _ = shm_unlink($0) }
            throw ShmFrameError.mapFailed(errno: code)
        }

        return ShmFrame(
            name: name,
            fd: fd,
            base: base,
            mappedBytes: mappedBytes,
            payloadBytes: payloadBytes
        )
    }

    /// Drops the mapping and the descriptor. Deliberately does not unlink, so
    /// the terminal still has a chance to read the segment.
    public func closeMapping() {
        munmap(base, mappedBytes)
        close(fd)
    }

    /// Removes the segment by name. Only call this once the frame is known to
    /// be finished with - the terminal cannot read a segment that is gone.
    public func unlink() {
        name.withCString { _ = shm_unlink($0) }
    }
}

/// Builds a shared memory name. The pid and counter are base36-encoded to stay
/// within the 31 byte limit, e.g. "/gs1n2p.5f".
public func makeShmName(pid: Int32, counter: UInt64) -> String {
    "/gs" + String(UInt32(bitPattern: pid), radix: 36) + "." + String(counter, radix: 36)
}
