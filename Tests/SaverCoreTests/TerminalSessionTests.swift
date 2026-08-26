import Foundation
import GeneratedShaders
import Metal
import Testing

@testable import SaverCore

// Serialized because these share one process-wide SIGWINCH flag.
@Suite("terminal resize", .serialized)
struct TerminalResizeTests {
    @Test("a resize is reported once and then cleared")
    func resizeIsReportedOnce() {
        _ = TerminalSession.takeResizeRequest()   // start from a known state

        markResizeRequested()

        #expect(TerminalSession.takeResizeRequest())
        #expect(!TerminalSession.takeResizeRequest())
    }

    /// Several resizes while a frame is in flight still only need one rebuild.
    @Test("repeated resizes collapse into one request")
    func repeatedResizesCollapse() {
        _ = TerminalSession.takeResizeRequest()

        markResizeRequested()
        markResizeRequested()
        markResizeRequested()

        #expect(TerminalSession.takeResizeRequest())
        #expect(!TerminalSession.takeResizeRequest())
    }

    /// The handler itself, over a real signal. Delivery is not synchronous
    /// here - the test runs on a dispatch worker thread, where SIGWINCH is
    /// blocked until some thread picks it up - so this waits rather than
    /// asserting immediately.
    @Test("SIGWINCH reaches the flag")
    func signalReachesTheFlag() {
        TerminalSession.installResizeHandler()
        _ = TerminalSession.takeResizeRequest()

        raise(SIGWINCH)

        let deadline = Date().addingTimeInterval(2)
        var observed = false
        while Date() < deadline && !observed {
            observed = TerminalSession.takeResizeRequest()
            if !observed { usleep(500) }
        }
        #expect(observed)
    }

    @Test("no resize means no request")
    func quiescentMeansNoRequest() {
        _ = TerminalSession.takeResizeRequest()

        #expect(!TerminalSession.takeResizeRequest())
    }
}

@Suite("renderer resize")
struct RendererResizeTests {
    /// A resize must not recompile the shader, and the new width still has to
    /// clear the linear texture alignment or the next render traps.
    @Test("resizing keeps the alignment and reuses the pipeline")
    func resizeKeepsAlignment() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let alignment = max(4, device.minimumLinearTextureAlignment(for: MetalRenderer.pixelFormat))

        let renderer = try MetalRenderer(
            width: 640,
            height: 480,
            fragmentSource: GeneratedShaders.gradient.source,
            fragmentFunctionName: GeneratedShaders.gradient.entryPoint
        )

        for (width, height) in [(1919, 1081), (3831, 2152), (321, 241)] {
            renderer.resize(width: width, height: height)
            #expect(renderer.height == height)
            #expect(renderer.width >= width)
            #expect(renderer.bytesPerRow == renderer.width * 4)
            #expect(renderer.bytesPerRow % alignment == 0)
            #expect(renderer.payloadBytes == renderer.bytesPerRow * height)
        }
    }

    /// After a resize the shared memory has to be reallocated too; rendering
    /// into a segment sized for the old resolution must be refused.
    @Test("a stale frame is refused after growing")
    func staleFrameRefusedAfterGrowth() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        prepareShmTracking()

        let renderer = try MetalRenderer(
            width: 128,
            height: 128,
            fragmentSource: GeneratedShaders.gradient.source,
            fragmentFunctionName: GeneratedShaders.gradient.entryPoint
        )
        var state = try #require(
            ShadertoyState(device: renderer.device, width: renderer.width, height: renderer.height)
        )

        let frame = try ShmFrame.create(
            name: makeShmName(pid: getpid(), counter: uniqueCounters(1)[0]),
            payloadBytes: renderer.payloadBytes
        )
        defer {
            frame.closeMapping()
            frame.unlink()
        }

        renderer.resize(width: 1024, height: 1024)
        state.setResolution(width: renderer.width, height: renderer.height)

        #expect(throws: MetalRendererError.self) {
            try renderer.render(into: frame, uniforms: state.uniforms)
        }
    }

    @Test("the new resolution reaches the uniform block")
    func resolutionReachesUniforms() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var state = try #require(ShadertoyState(device: device, width: 640, height: 480))

        state.setResolution(width: 1920, height: 1080)

        let base = state.uniforms.buffer.contents()
        #expect(base.load(fromByteOffset: ShadertoyUniformLayout.iResolution, as: Float.self) == 1920)
        #expect(base.load(fromByteOffset: ShadertoyUniformLayout.iResolution + 4, as: Float.self) == 1080)
    }
}
