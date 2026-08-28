import Foundation
import GeneratedShaders
import Metal
import Testing

@testable import SaverCore

/// Renders a shader once and hands back the pixels, so tests can describe what
/// a shader looks like without a terminal.
struct RenderedFrame {
    /// The instant every test render is pinned to. iDate is real wall-clock
    /// time in the screensaver, and two renders milliseconds apart would give a
    /// shader that reads it two different frames.
    static let pinnedDate = Date(timeIntervalSince1970: 1_768_478_400)  // 2026-01-15T12:00:00Z

    let width: Int
    let height: Int
    let bytesPerRow: Int
    let pixels: [UInt8]

    static func make(
        program: ShaderProgram, width: Int, height: Int, time: Float, date: Date = pinnedDate
    ) throws -> RenderedFrame? {
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
        state.update(time: time, frame: Int(time * 60), frameRate: 60, date: date)

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

    /// Renders a named shader, or nothing on a machine with no Metal device.
    static func make(
        named name: String, width: Int, height: Int, time: Float, date: Date = pinnedDate
    ) throws -> RenderedFrame? {
        let program = try #require(
            GeneratedShaders.all.first { $0.name == name },
            "no shader named \(name) in the catalog"
        )
        return try make(program: program, width: width, height: height, time: time, date: date)
    }

    func channelMeans(rows: Range<Int>) -> (red: Double, green: Double, blue: Double) {
        var totals = (0.0, 0.0, 0.0)
        for y in rows {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                totals.0 += Double(pixels[offset])
                totals.1 += Double(pixels[offset + 1])
                totals.2 += Double(pixels[offset + 2])
            }
        }
        let count = Double(width * rows.count)
        return (totals.0 / count, totals.1 / count, totals.2 / count)
    }

    func channelMeans() -> (red: Double, green: Double, blue: Double) {
        channelMeans(rows: 0..<height)
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

    /// Mean of the three channels over the whole frame.
    func brightness() -> Double {
        let means = channelMeans()
        return (means.red + means.green + means.blue) / 3
    }

    /// The brightest single channel value anywhere in the frame.
    func peak() -> UInt8 {
        var highest: UInt8 = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                highest = max(highest, max(pixels[offset], max(pixels[offset + 1], pixels[offset + 2])))
            }
        }
        return highest
    }

    /// Fraction of pixels that differ from another frame by more than `levels`
    /// in some channel. Asking for a margin rather than for any difference at
    /// all is what separates a shader that moves from one that lands a step of
    /// quantisation away from where it was.
    func fractionDiffering(from other: RenderedFrame, byMoreThan levels: Int) -> Double {
        precondition(width == other.width && height == other.height)
        var moved = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                let otherOffset = y * other.bytesPerRow + x * 4
                for channel in 0..<3 where
                    abs(Int(pixels[offset + channel]) - Int(other.pixels[otherOffset + channel])) > levels {
                    moved += 1
                    break
                }
            }
        }
        return Double(moved) / Double(width * height)
    }
}

/// Every shader the catalog carries, by name. A file-scope constant because
/// that is what `@Test(arguments:)` can reach.
private let shaderNames = GeneratedShaders.all.map(\.name)

/// What every shader in the catalog has to do, whatever it happens to draw.
@Suite("every shader")
struct ShaderInvariantTests {
    @Test("it compiles", arguments: shaderNames)
    func compiles(name: String) throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let program = try #require(GeneratedShaders.all.first { $0.name == name })
        _ = try MetalRenderer(
            width: 64,
            height: 64,
            fragmentSource: program.source,
            fragmentFunctionName: program.entryPoint
        )
    }

    /// The same iTime must produce the same frame; a shader here carries no
    /// state between frames, which is what lets it also run as a Ghostty
    /// custom-shader.
    @Test("the same time produces the same frame", arguments: shaderNames)
    func isStateless(name: String) throws {
        guard let first = try RenderedFrame.make(named: name, width: 256, height: 192, time: 4.25),
              let second = try RenderedFrame.make(named: name, width: 256, height: 192, time: 4.25) else {
            return
        }
        #expect(first.pixels == second.pixels)
    }

    /// Everything is derived from iTime, so a different iTime has to produce a
    /// visibly different frame. A shader that ignored time would still pass
    /// every other check here.
    ///
    /// The margin is the point. Asking only that the two frames differ is a
    /// check a shader can pass by moving a single step of quantisation, which
    /// is what gradient.glsl does over a pair of times four seconds apart on
    /// the flat of its sine.
    @Test("the frame changes over time", arguments: shaderNames)
    func animatesOverTime(name: String) throws {
        guard let first = try RenderedFrame.make(named: name, width: 256, height: 192, time: 2.0),
              let second = try RenderedFrame.make(named: name, width: 256, height: 192, time: 6.0) else {
            return
        }
        let moved = first.fractionDiffering(from: second, byMoreThan: 8)
        #expect(moved > 0.02, "\(name) barely moves between the two times (\(moved) of the frame)")
    }

    /// A shader tuned to one resolution tends to draw nothing, or a flat wash,
    /// at another. Both are caught by asking for something and some contrast.
    @Test("it draws something at every resolution", arguments: shaderNames)
    func drawsAtAnyResolution(name: String) throws {
        for (width, height) in [(320, 240), (1280, 720)] {
            guard let frame = try RenderedFrame.make(
                named: name, width: width, height: height, time: 6.5
            ) else { return }

            #expect(frame.peak() > 40, "\(name) at \(width)x\(height) drew nothing to speak of")
            #expect(frame.brightness() < 250, "\(name) at \(width)x\(height) is a white screen")
        }
    }

    /// The listing is generated from the leading comment of each shader, so an
    /// empty one means a shader was added without saying what it draws.
    @Test("it says what it draws", arguments: shaderNames)
    func hasASummary(name: String) throws {
        let program = try #require(GeneratedShaders.all.first { $0.name == name })
        #expect(!program.summary.isEmpty)
        #expect(program.summary.count < 200, "\(name)'s summary is too long for a listing")
    }
}

@Suite("matrix shader")
struct MatrixShaderTests {
    /// The point of a screensaver is a mostly dark screen with rain on it, not
    /// a wall of green.
    @Test("the screen is mostly dark")
    func mostlyDark() throws {
        guard let frame = try RenderedFrame.make(named: "matrix", width: 640, height: 480, time: 7.5) else {
            return
        }
        let lit = frame.litFraction(threshold: 32)
        #expect(lit > 0.01, "nothing is being drawn (lit fraction \(lit))")
        #expect(lit < 0.35, "too dense to read as rain (lit fraction \(lit))")
    }

    @Test("green dominates the other channels")
    func greenDominates() throws {
        guard let frame = try RenderedFrame.make(named: "matrix", width: 640, height: 480, time: 7.5) else {
            return
        }
        let means = frame.channelMeans()
        #expect(means.green > means.red * 2)
        #expect(means.green > means.blue * 1.5)
    }

    /// Depth comes from running the same field at several scales, so the look
    /// has to survive a change of resolution rather than being tuned to one.
    @Test("the rain stays rain at every resolution", arguments: [
        (320, 240), (1280, 720), (1920, 1080),
    ])
    func staysRain(width: Int, height: Int) throws {
        guard let frame = try RenderedFrame.make(named: "matrix", width: width, height: height, time: 5.0) else {
            return
        }
        let lit = frame.litFraction(threshold: 32)
        #expect(lit > 0.005, "\(width)x\(height) drew almost nothing (lit fraction \(lit))")
        #expect(lit < 0.35, "\(width)x\(height) is too dense (lit fraction \(lit))")
    }
}

/// One check per shader for the thing that makes it that shader rather than
/// some other one. These are deliberately loose: they are here to catch a
/// shader that has stopped drawing what its name says, not to pin down a look.
@Suite("what each screensaver looks like")
struct ShaderAppearanceTests {
    @Test("the crawl is yellow text on a dark sky")
    func crawlIsYellow() throws {
        guard let frame = try RenderedFrame.make(named: "starwars", width: 640, height: 360, time: 132.0) else {
            return
        }
        // The text lives in the bottom half; the top is sky.
        let text = frame.channelMeans(rows: (frame.height / 2)..<frame.height)
        #expect(text.red > text.blue * 2, "the crawl has lost its yellow")
        #expect(text.green > text.blue * 2, "the crawl has lost its yellow")
        #expect(text.red > text.green, "the crawl should be warmer than green")
        #expect(frame.brightness() < 60, "the sky should be dark behind it")
    }

    /// The crawl is a fixed number of columns wide, so a narrow window has to
    /// push it further away rather than running it off both sides.
    @Test("the crawl fits inside a narrow window")
    func crawlFitsNarrow() throws {
        guard let narrow = try RenderedFrame.make(named: "starwars", width: 480, height: 480, time: 132.0) else {
            return
        }
        // No crawl ink should reach the left or right edge: the widest line is
        // meant to stop short of them.
        //
        // The blue test is what makes this about the text. The stars are
        // bright and go right to the edge, and they are white - so it is the
        // lack of blue, not the brightness, that says a pixel is yellow.
        var edgeInk = 0
        for y in 0..<narrow.height {
            for x in [0, 1, narrow.width - 2, narrow.width - 1] {
                let offset = y * narrow.bytesPerRow + x * 4
                let red = Int(narrow.pixels[offset])
                let green = Int(narrow.pixels[offset + 1])
                let blue = Int(narrow.pixels[offset + 2])
                if red > 90 && green > 60 && blue * 2 < red { edgeInk += 1 }
            }
        }
        #expect(edgeInk == 0, "\(edgeInk) crawl pixels are running off the edge")
    }

    /// The whole point of the shader is the jump, and the jump is a flash.
    @Test("hyperspace flashes when it jumps")
    func hyperspaceJumps() throws {
        guard let cruising = try RenderedFrame.make(named: "hyperspace", width: 320, height: 240, time: 8.0),
              let jumping = try RenderedFrame.make(named: "hyperspace", width: 320, height: 240, time: 22.0) else {
            return
        }
        #expect(cruising.brightness() < 30, "the cruise should be a dark sky with stars in it")
        #expect(jumping.brightness() > cruising.brightness() * 4, "the jump did not flash")
    }

    @Test("mystify draws thin bright lines on black")
    func mystifyDrawsLines() throws {
        guard let frame = try RenderedFrame.make(named: "mystify", width: 640, height: 360, time: 12.0) else {
            return
        }
        #expect(frame.peak() > 180, "the ribbons should be bright")
        let lit = frame.litFraction(threshold: 96)
        #expect(lit > 0.001, "nothing is being drawn (lit fraction \(lit))")
        #expect(lit < 0.30, "these are meant to be lines, not fills (lit fraction \(lit))")
    }

    /// The tunnel is bright seams on dark panels rather than a lit surface, so
    /// it has to stay a cool wireframe: a high peak over a low mean. Where the
    /// vanishing point lands is not checked, because the camera sways and it
    /// moves.
    @Test("the tunnel is a cool wireframe on the dark")
    func tunnelIsWireframe() throws {
        guard let frame = try RenderedFrame.make(named: "tunnel", width: 640, height: 360, time: 9.0) else {
            return
        }
        let means = frame.channelMeans()
        #expect(means.blue > means.red * 1.5, "the tunnel should be cool, not warm")
        #expect(frame.peak() > 180, "the seams should be bright")
        #expect(frame.brightness() < 90, "the panels between them should not be (mean \(frame.brightness()))")
    }

    @Test("synthwave puts a warm sun over a cool grid")
    func synthwaveIsSplit() throws {
        guard let frame = try RenderedFrame.make(named: "synthwave", width: 640, height: 360, time: 11.0) else {
            return
        }
        let sky = frame.channelMeans(rows: 0..<(frame.height / 3))
        let ground = frame.channelMeans(rows: (frame.height * 2 / 3)..<frame.height)
        #expect(sky.red > sky.blue, "the sky and sun should be warm")
        #expect(ground.blue > ground.red, "the grid should be cool")
    }

    @Test("the toasters are bright against a dark sky")
    func toastersFly() throws {
        guard let frame = try RenderedFrame.make(named: "toasters", width: 640, height: 360, time: 20.0) else {
            return
        }
        #expect(frame.peak() > 200, "chrome should be bright")
        let covered = frame.litFraction(threshold: 40)
        #expect(covered > 0.03, "the sky is empty (covered fraction \(covered))")
        #expect(covered < 0.70, "the flock has taken over the sky (covered fraction \(covered))")
    }

    @Test("the aurora is green over a dark ridge")
    func auroraIsGreen() throws {
        guard let frame = try RenderedFrame.make(named: "aurora", width: 640, height: 360, time: 63.0) else {
            return
        }
        // The sky behind is deliberately blue, so the whole-frame average says
        // nothing. It is the lit parts that have to be green.
        var totals = (red: 0.0, green: 0.0, blue: 0.0)
        var count = 0.0
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let offset = y * frame.bytesPerRow + x * 4
                guard frame.pixels[offset + 1] > 60 else { continue }
                totals.red += Double(frame.pixels[offset])
                totals.green += Double(frame.pixels[offset + 1])
                totals.blue += Double(frame.pixels[offset + 2])
                count += 1
            }
        }
        #expect(count > Double(frame.width * frame.height) * 0.01, "the curtains have gone out")
        #expect(totals.green > totals.red * 2, "the curtains have lost their green")

        // The bottom of the frame is land, and land is black.
        let land = frame.channelMeans(rows: (frame.height - 12)..<frame.height)
        let landMean = (land.red + land.green + land.blue) / 3
        #expect(landMean < 12, "the ridge line should be dark (mean \(landMean))")
    }
}
