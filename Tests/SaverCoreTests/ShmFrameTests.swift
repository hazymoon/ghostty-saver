import CShim
import Foundation
import Testing

@testable import SaverCore

/// Hands out counters that no other test will reuse, since the shared memory
/// namespace is per-user and the whole suite runs in one process.
private let counterSource = ManagedAtomicCounter(start: 100_000)

func uniqueCounters(_ count: Int) -> [UInt64] {
    (0..<count).map { _ in counterSource.next() }
}

func shmSegmentExists(_ name: String) -> Bool {
    let fd = name.withCString { gs_shm_open_readonly($0) }
    if fd >= 0 {
        close(fd)
        return true
    }
    return false
}

/// A counter guarded by a lock. Small enough not to justify a dependency.
final class ManagedAtomicCounter {
    private var value: UInt64
    private let lock = NSLock()

    init(start: UInt64) { value = start }

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

// Serialized because every case shares one process-wide tracking ring.
@Suite("shared memory frames", .serialized)
struct ShmFrameTests {
    /// macOS caps names at 31 bytes including the leading slash, so the encoding
    /// has to stay short even at the extremes of pid and frame counter.
    @Test("names stay inside the 31-byte limit")
    func nameLength() {
        let extremes: [(Int32, UInt64)] = [
            (1, 0),
            (99999, 0),
            (Int32.max, UInt64(UInt32.max)),
            (-1, UInt64.max),
        ]
        for (pid, counter) in extremes {
            let name = makeShmName(pid: pid, counter: counter)
            #expect(name.hasPrefix("/"))
            #expect(name.utf8.count <= shmNameMaxBytes, "\(name) is \(name.utf8.count) bytes")
        }
    }

    @Test("each frame gets its own name")
    func namesAreDistinct() {
        let names = (0..<128).map { makeShmName(pid: getpid(), counter: UInt64($0)) }
        #expect(Set(names).count == names.count)
    }

    @Test("the mapping is page-aligned and large enough")
    func mappingGeometry() throws {
        prepareShmTracking()
        let pageSize = Int(getpagesize())
        // Deliberately not a multiple of the page size.
        let payloadBytes = pageSize * 3 + 17

        let frame = try ShmFrame.create(
            name: makeShmName(pid: getpid(), counter: 1001),
            payloadBytes: payloadBytes
        )
        defer {
            frame.closeMapping()
            frame.unlink()
        }

        #expect(frame.payloadBytes == payloadBytes)
        #expect(frame.mappedBytes >= payloadBytes)
        #expect(frame.mappedBytes % pageSize == 0)
        // makeBuffer(bytesNoCopy:) requires a page-aligned pointer.
        #expect(Int(bitPattern: frame.base) % pageSize == 0)
    }

    @Test("the mapping is writable and reads back")
    func mappingIsWritable() throws {
        prepareShmTracking()
        let frame = try ShmFrame.create(
            name: makeShmName(pid: getpid(), counter: 1002),
            payloadBytes: 256
        )
        defer {
            frame.closeMapping()
            frame.unlink()
        }

        let bytes = frame.base.assumingMemoryBound(to: UInt8.self)
        for i in 0..<256 { bytes[i] = UInt8(i) }
        #expect(bytes[0] == 0)
        #expect(bytes[255] == 255)
    }

    /// Creation uses O_EXCL so a stale segment is never silently adopted.
    @Test("creating the same name twice fails")
    func duplicateNameFails() throws {
        prepareShmTracking()
        let name = makeShmName(pid: getpid(), counter: 1003)
        let first = try ShmFrame.create(name: name, payloadBytes: 64)
        defer {
            first.closeMapping()
            first.unlink()
        }

        #expect(throws: ShmFrameError.self) {
            _ = try ShmFrame.create(name: name, payloadBytes: 64)
        }
    }

    @Test("an over-long name is rejected before shm_open")
    func overLongNameRejected() {
        let name = "/" + String(repeating: "x", count: shmNameMaxBytes)
        #expect(throws: ShmFrameError.self) {
            _ = try ShmFrame.create(name: name, payloadBytes: 64)
        }
    }

    /// Nothing here plays the terminal's part, so no segment is ever unlinked
    /// externally. The tracking ring has to reclaim the old ones itself,
    /// otherwise a run leaks segments until reboot.
    @Test("segments older than the ring are reclaimed")
    func oldSegmentsAreReclaimed() throws {
        prepareShmTracking()
        defer { unlinkTrackedShm() }

        let total = 64
        var frames: [ShmFrame] = []
        for counter in uniqueCounters(total) {
            let frame = try ShmFrame.create(name: makeShmName(pid: getpid(), counter: counter), payloadBytes: 64)
            frame.closeMapping()
            frames.append(frame)
        }
        defer { frames.forEach { $0.unlink() } }

        let alive = frames.filter { shmSegmentExists($0.name) }
        #expect(alive.count < total, "every segment survived; the ring is not reclaiming")
        #expect(alive.count <= 16, "\(alive.count) segments outstanding")
        // Anything from the first three quarters is far enough back that it
        // must be gone regardless of what else is running.
        #expect(frames.prefix(total * 3 / 4).allSatisfy { !shmSegmentExists($0.name) })
    }

    /// Reclaiming too eagerly would destroy a frame the terminal has not read
    /// yet, which is a dropped frame rather than a leak.
    @Test("recent segments are left alone")
    func recentSegmentsSurvive() throws {
        prepareShmTracking()

        var frames: [ShmFrame] = []
        for counter in uniqueCounters(3) {
            let frame = try ShmFrame.create(name: makeShmName(pid: getpid(), counter: counter), payloadBytes: 64)
            frame.closeMapping()
            frames.append(frame)
        }
        defer { frames.forEach { $0.unlink() } }

        #expect(frames.allSatisfy { shmSegmentExists($0.name) })
    }

    @Test("unlinkTrackedShm removes what is left")
    func unlinkClearsEverything() throws {
        prepareShmTracking()
        let frame = try ShmFrame.create(
            name: makeShmName(pid: getpid(), counter: 3000),
            payloadBytes: 64
        )
        frame.closeMapping()

        unlinkTrackedShm()

        #expect(!shmSegmentExists(frame.name))
    }
}
