import Foundation
import GeneratedShaders
import Metal
import Testing

@testable import SaverCore

/// Renders a shader once and hands back the pixels, so tests can describe what
/// a shader looks like without a terminal.
struct RenderedFrame {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let pixels: [UInt8]

    static func make(program: ShaderProgram, width: Int, height: Int, time: Float) throws -> RenderedFrame? {
        shmExclusive.lock()
        defer { shmExclusive.unlock() }

        guard MTLCreateSystemDefaultDevice() != nil else { return nil }
        prepareShmTracking()

        let renderer = try MetalRenderer(
            width: width,
            height: height,
            fragmentSource: program.source,
            fragmentFunctionName: program.entryPoint
        )
        var state = try #require(
            ShadertoyState(device: renderer.device, width: renderer.width, height: renderer.height)
        )
        state.update(time: time, frame: Int(time * 60), frameRate: 60)

        let frame = try ShmFrame.create(
            name: makeShmName(pid: getpid(), counter: uniqueCounters(1)[0]),
            payloadBytes: renderer.payloadBytes
        )
        defer {
            frame.closeMapping()
            frame.unlink()
        }

        try renderer.render(into: frame, uniforms: state.uniforms)

        let raw = frame.base.assumingMemoryBound(to: UInt8.self)
        return RenderedFrame(
            width: renderer.width,
            height: renderer.height,
            bytesPerRow: renderer.bytesPerRow,
            pixels: Array(UnsafeBufferPointer(start: raw, count: renderer.bytesPerRow * renderer.height))
        )
    }

    func channelMeans() -> (red: Double, green: Double, blue: Double) {
        var totals = (0.0, 0.0, 0.0)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                totals.0 += Double(pixels[offset])
                totals.1 += Double(pixels[offset + 1])
                totals.2 += Double(pixels[offset + 2])
            }
        }
        let count = Double(width * height)
        return (totals.0 / count, totals.1 / count, totals.2 / count)
    }

    /// Fraction of pixels whose green channel is above the given threshold.
    func litFraction(threshold: UInt8) -> Double {
        var lit = 0
        for y in 0..<height {
            for x in 0..<width where pixels[y * bytesPerRow + x * 4 + 1] > threshold {
                lit += 1
            }
        }
        return Double(lit) / Double(width * height)
    }
}

@Suite("matrix shader")
struct MatrixShaderTests {
    private let program = GeneratedShaders.matrix

    /// The point of a screensaver is a mostly dark screen with rain on it, not
    /// a wall of green.
    @Test("the screen is mostly dark")
    func mostlyDark() throws {
        guard let frame = try RenderedFrame.make(program: program, width: 640, height: 480, time: 7.5) else {
            return
        }
        let lit = frame.litFraction(threshold: 32)
        #expect(lit > 0.01, "nothing is being drawn (lit fraction \(lit))")
        #expect(lit < 0.35, "too dense to read as rain (lit fraction \(lit))")
    }

    @Test("green dominates the other channels")
    func greenDominates() throws {
        guard let frame = try RenderedFrame.make(program: program, width: 640, height: 480, time: 7.5) else {
            return
        }
        let means = frame.channelMeans()
        #expect(means.green > means.red * 2)
        #expect(means.green > means.blue * 1.5)
    }

    /// Everything is derived from iTime, so a different iTime has to produce a
    /// different frame. A shader that ignored time would still pass every
    /// other check here.
    @Test("the frame changes over time")
    func animatesOverTime() throws {
        guard let first = try RenderedFrame.make(program: program, width: 320, height: 240, time: 2.0),
              let second = try RenderedFrame.make(program: program, width: 320, height: 240, time: 9.0) else {
            return
        }
        #expect(first.pixels != second.pixels)
    }

    /// The same iTime must produce the same frame; the shader carries no state
    /// between frames, which is what lets it also run as a Ghostty
    /// custom-shader.
    @Test("the same time produces the same frame")
    func isStateless() throws {
        guard let first = try RenderedFrame.make(program: program, width: 320, height: 240, time: 4.25),
              let second = try RenderedFrame.make(program: program, width: 320, height: 240, time: 4.25) else {
            return
        }
        #expect(first.pixels == second.pixels)
    }

    /// Depth comes from running the same field at several scales, so the look
    /// has to survive a change of resolution rather than being tuned to one.
    @Test("it draws something at every resolution", arguments: [
        (320, 240), (1280, 720), (1920, 1080),
    ])
    func drawsAtAnyResolution(width: Int, height: Int) throws {
        guard let frame = try RenderedFrame.make(program: program, width: width, height: height, time: 5.0) else {
            return
        }
        let lit = frame.litFraction(threshold: 32)
        #expect(lit > 0.005, "\(width)x\(height) drew almost nothing (lit fraction \(lit))")
        #expect(lit < 0.35, "\(width)x\(height) is too dense (lit fraction \(lit))")
    }

    @Test("every shader in the catalog compiles")
    func allShadersCompile() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        for program in GeneratedShaders.all {
            _ = try MetalRenderer(
                width: 64,
                height: 64,
                fragmentSource: program.source,
                fragmentFunctionName: program.entryPoint
            )
        }
    }
}
