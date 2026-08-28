import Foundation
import GeneratedShaders
import Metal
import Testing

@testable import SaverCore

@Suite("Metal renderer")
struct RendererTests {
    /// Everything here needs a GPU. Machines without one skip rather than fail.
    private var device: MTLDevice? { MTLCreateSystemDefaultDevice() }

    /// A buffer-backed linear texture traps - it does not return nil - when
    /// bytesPerRow misses the device's alignment, so the padding is what keeps
    /// an odd terminal width from crashing the process.
    @Test("width is padded until bytesPerRow meets the device alignment")
    func widthPadding() throws {
        guard let device else { return }
        let alignment = max(4, device.minimumLinearTextureAlignment(for: MetalRenderer.pixelFormat))

        for requested in [1, 2, 3, 639, 640, 1919, 1920, 3831, 3832, 3833] {
            let padded = MetalRenderer.alignedWidth(requested, device: device)
            #expect(padded >= requested)
            #expect(padded * 4 % alignment == 0, "width \(requested) padded to \(padded)")
            // Padding must stay tight enough to be invisible.
            #expect(padded - requested < alignment / 4 + 1)
        }
    }

    @Test("an already aligned width is left alone")
    func alignedWidthIsIdempotent() throws {
        guard let device else { return }
        let padded = MetalRenderer.alignedWidth(3832, device: device)
        #expect(MetalRenderer.alignedWidth(padded, device: device) == padded)
    }

    /// The whole design rests on the GPU writing into shared memory with no
    /// readback, so this checks the pixels through the shared memory mapping
    /// rather than through Metal.
    @Test("the GPU writes land in shared memory")
    func rendersIntoSharedMemory() throws {
        shmExclusive.lock()
        defer { shmExclusive.unlock() }

        guard MTLCreateSystemDefaultDevice() != nil else { return }
        prepareShmTracking()

        let renderer = try MetalRenderer(
            width: 64,
            height: 32,
            fragmentSource: GeneratedShaders.gradient.source,
            fragmentFunctionName: GeneratedShaders.gradient.entryPoint
        )
        var state = try #require(
            ShadertoyState(device: renderer.device, width: renderer.width, height: renderer.height)
        )
        state.update(time: 0, frame: 0, frameRate: 60, date: Date())

        let frame = try ShmFrame.create(
            name: makeShmName(pid: getpid(), counter: uniqueCounters(1)[0]),
            payloadBytes: renderer.payloadBytes
        )
        defer {
            frame.closeMapping()
            frame.unlink()
        }

        // Fill with a sentinel so an unwritten target cannot pass by accident.
        memset(frame.base, 0x5A, frame.mappedBytes)
        try renderer.render(into: frame, uniforms: state.uniforms)

        let pixels = frame.base.assumingMemoryBound(to: UInt8.self)
        func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
            let offset = y * renderer.bytesPerRow + x * 4
            return (pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3])
        }

        // gradient.glsl is red along x, green along y, and at iTime 0 the blue
        // channel is 0.5.
        let topLeft = pixel(0, 0)
        let topRight = pixel(renderer.width - 1, 0)
        let bottomLeft = pixel(0, renderer.height - 1)
        let bottomRight = pixel(renderer.width - 1, renderer.height - 1)

        #expect(topLeft.0 < 16 && topLeft.1 < 16)
        #expect(topRight.0 > 240 && topRight.1 < 16)
        #expect(bottomLeft.0 < 16 && bottomLeft.1 > 240)
        #expect(bottomRight.0 > 240 && bottomRight.1 > 240)

        // Byte order is RGBA, not BGRA: the red ramp must live in byte 0.
        #expect(topRight.0 > topRight.2)
        // Blue is uniform and alpha is opaque everywhere. The fixture goes
        // out through the RGB555 dither, so 0.5 lands on level 15 or 16 of
        // 31 - 124 or 132 - depending on the Bayer threshold at that pixel.
        for corner in [topLeft, topRight, bottomLeft, bottomRight] {
            #expect(abs(Int(corner.2) - 128) <= 5)
            #expect(corner.3 == 255)
        }
    }

    /// A shared memory segment sized for a different resolution must be caught
    /// before Metal reads past the end of it.
    @Test("a frame that is too small is rejected")
    func rejectsUndersizedFrame() throws {
        shmExclusive.lock()
        defer { shmExclusive.unlock() }

        guard MTLCreateSystemDefaultDevice() != nil else { return }
        prepareShmTracking()

        let renderer = try MetalRenderer(
            width: 256,
            height: 256,
            fragmentSource: GeneratedShaders.gradient.source,
            fragmentFunctionName: GeneratedShaders.gradient.entryPoint
        )
        let state = try #require(
            ShadertoyState(device: renderer.device, width: renderer.width, height: renderer.height)
        )

        let frame = try ShmFrame.create(
            name: makeShmName(pid: getpid(), counter: uniqueCounters(1)[0]),
            payloadBytes: 64 * 64 * 4
        )
        defer {
            frame.closeMapping()
            frame.unlink()
        }

        #expect(throws: MetalRendererError.self) {
            try renderer.render(into: frame, uniforms: state.uniforms)
        }
    }

    @Test("a shader that does not compile is reported, not crashed on")
    func reportsBadShader() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        #expect(throws: MetalRendererError.self) {
            _ = try MetalRenderer(
                width: 16,
                height: 16,
                fragmentSource: "this is not MSL",
                fragmentFunctionName: "main0"
            )
        }
    }

    @Test("a missing entry point is reported")
    func reportsMissingEntryPoint() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        #expect(throws: MetalRendererError.self) {
            _ = try MetalRenderer(
                width: 16,
                height: 16,
                fragmentSource: GeneratedShaders.gradient.source,
                fragmentFunctionName: "no_such_function"
            )
        }
    }
}
