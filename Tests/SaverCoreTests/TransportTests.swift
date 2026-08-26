import Foundation
import Testing

@testable import SaverCore

/// A pipe whose write end is handed to code under test and whose read end the
/// test drains.
struct TestPipe {
    let readEnd: Int32
    let writeEnd: Int32

    init() throws {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        readEnd = fds[0]
        writeEnd = fds[1]
    }

    func close() {
        Foundation.close(readEnd)
        Foundation.close(writeEnd)
    }

    /// Reads whatever is buffered without blocking on an empty pipe.
    func drain() -> [UInt8] {
        var flags = fcntl(readEnd, F_GETFL, 0)
        flags |= O_NONBLOCK
        _ = fcntl(readEnd, F_SETFL, flags)

        var collected: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBytes { read(readEnd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            collected.append(contentsOf: chunk[0..<n])
        }
        return collected
    }
}

@Suite("kitty graphics transfer")
struct TransportTests {
    /// send() only reads the frame's name, so these tests describe a frame
    /// rather than allocating real shared memory. That keeps them out of the
    /// global tracking ring that the shared memory tests exercise.
    private func describeFrame(counter: UInt64) -> ShmFrame {
        ShmFrame(
            name: makeShmName(pid: getpid(), counter: counter),
            fd: -1,
            base: UnsafeMutableRawPointer(bitPattern: 0x1000)!,
            mappedBytes: 4096,
            payloadBytes: 4
        )
    }

    @Test("the escape sequence carries every key the protocol needs")
    func escapeSequenceShape() throws {
        let pipe = try TestPipe()
        defer { pipe.close() }

        let transport = KittySharedMemoryTransport(
            fd: pipe.writeEnd,
            width: 1920,
            height: 1080,
            imageID: 7,
            placementID: 3,
            quiet: .verbose
        )
        let frame = describeFrame(counter: 1)

        _ = try transport.send(frame: frame)
        let sent = String(decoding: pipe.drain(), as: UTF8.self)

        let expectedPayload = Data(frame.name.utf8).base64EncodedString()
        #expect(sent == "\u{1b}[H\u{1b}_Ga=T,f=32,s=1920,v=1080,t=s,i=7,p=3,q=0,C=1;\(expectedPayload)\u{1b}\\")
    }

    /// Omitting p makes Ghostty accumulate one placement per frame, so a pinned
    /// placement id is not optional.
    @Test("a placement id is always sent")
    func placementIDIsPresent() throws {
        let pipe = try TestPipe()
        defer { pipe.close() }

        let transport = KittySharedMemoryTransport(fd: pipe.writeEnd, width: 8, height: 8, quiet: .verbose)
        let frame = describeFrame(counter: 2)

        _ = try transport.send(frame: frame)
        let sent = String(decoding: pipe.drain(), as: UTF8.self)

        #expect(sent.contains(",p=1,"))
        #expect(!sent.contains(",p=0,"))
    }

    @Test("the quiet level reaches the wire", arguments: [
        (QuietLevel.verbose, "q=0"),
        (QuietLevel.errorsOnly, "q=1"),
        (QuietLevel.silent, "q=2"),
    ])
    func quietLevelIsEncoded(level: QuietLevel, expected: String) throws {
        let pipe = try TestPipe()
        defer { pipe.close() }

        let transport = KittySharedMemoryTransport(fd: pipe.writeEnd, width: 8, height: 8, quiet: level)
        let frame = describeFrame(counter: 3)

        _ = try transport.send(frame: frame)
        #expect(String(decoding: pipe.drain(), as: UTF8.self).contains(expected))
    }

    /// The payload is the shared memory name, not image data, and the terminal
    /// passes it straight to shm_open - so the leading slash has to survive.
    @Test("the payload is the base64 of the shared memory name")
    func payloadIsTheName() throws {
        let pipe = try TestPipe()
        defer { pipe.close() }

        let transport = KittySharedMemoryTransport(fd: pipe.writeEnd, width: 8, height: 8, quiet: .silent)
        let frame = describeFrame(counter: 4)

        _ = try transport.send(frame: frame)
        let sent = String(decoding: pipe.drain(), as: UTF8.self)

        let payload = try #require(sent.split(separator: ";").last?.dropLast(2))
        let decoded = try #require(Data(base64Encoded: String(payload)))
        #expect(String(decoding: decoded, as: UTF8.self) == frame.name)
        #expect(frame.name.hasPrefix("/"))
    }

    @Test("deleteAll clears every image and placement")
    func deleteAllSequence() throws {
        let pipe = try TestPipe()
        defer { pipe.close() }

        let transport = KittySharedMemoryTransport(fd: pipe.writeEnd, width: 8, height: 8, quiet: .silent)
        try transport.deleteAll()

        #expect(String(decoding: pipe.drain(), as: UTF8.self) == "\u{1b}_Ga=d,d=A\u{1b}\\")
    }
}
