import Foundation
import Metal
import Testing

@testable import SaverCore

/// shaders/lib/dither.glsl rounds every channel to 32 levels. The fixture
/// goes out through it, so a frame of the fixture is where that is checked.
@Suite("RGB555 dither")
struct DitherTests {
    /// Distinct values one channel takes over the frame.
    private func levels(of frame: RenderedFrame, channel: Int) -> Set<UInt8> {
        var seen = Set<UInt8>()
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                seen.insert(frame.pixels[y * frame.bytesPerRow + x * 4 + channel])
            }
        }
        return seen
    }

    @Test("the fixture leaves with no more than 32 levels per channel")
    func quantisedTo32() throws {
        guard let frame = try RenderedFrame.make(named: "gradient", width: 640, height: 360, time: 1.0) else {
            return
        }
        for channel in 0..<3 {
            let count = levels(of: frame, channel: channel).count
            #expect(count <= 32, "channel \(channel) has \(count) levels")
        }
        // Still a gradient on the two ramped channels: the quantisation must
        // not have flattened them. Blue is a flat pulse and may sit on one
        // level, or dither between two.
        for channel in 0..<2 {
            let count = levels(of: frame, channel: channel).count
            #expect(count > 2, "channel \(channel) has collapsed to \(count) levels")
        }
    }

    /// The threshold is added before the rounding, so along a slow ramp a
    /// pixel and its neighbour can land on different levels. Rounding first
    /// would give runs of identical pixels the width of a whole level.
    @Test("neighbouring pixels differ inside a level, which is the dither")
    func dithersWithinALevel() throws {
        guard let frame = try RenderedFrame.make(named: "gradient", width: 640, height: 360, time: 1.0) else {
            return
        }
        // Red runs left to right over 640 px and 32 levels: 20 px per level.
        // Count horizontal neighbours that differ in red; without the
        // threshold there would be at most 31 steps per row.
        var steps = 0
        let y = frame.height / 2
        for x in 1..<frame.width {
            let offset = y * frame.bytesPerRow + x * 4
            if frame.pixels[offset] != frame.pixels[offset - 4] { steps += 1 }
        }
        #expect(steps > 31 * 2, "only \(steps) level changes across the row: no dither")
    }
}
