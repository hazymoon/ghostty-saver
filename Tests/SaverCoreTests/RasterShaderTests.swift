import Foundation
import Metal
import Testing

@testable import SaverCore

/// The raster shader is a 16-bit sunset read back with a per-scanline offset.
/// What has to hold is the era, not the wave: a warm sky over a dark ground,
/// and the 32-level signature of the dither it goes out through.
@Suite("raster shader")
struct RasterShaderTests {
    private func levels(of frame: RenderedFrame, channel: Int) -> Set<UInt8> {
        var seen = Set<UInt8>()
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                seen.insert(frame.pixels[y * frame.bytesPerRow + x * 4 + channel])
            }
        }
        return seen
    }

    @Test("a warm sky sits over a dark ground")
    func warmSkyDarkGround() throws {
        guard let frame = try RenderedFrame.make(named: "raster", width: 640, height: 360, time: 5.0) else {
            return
        }
        let sky = frame.channelMeans(rows: (frame.height / 5)..<(frame.height / 2))
        let ground = frame.channelMeans(rows: (frame.height * 4 / 5)..<frame.height)
        #expect(sky.red > sky.blue, "the sunset sky should be warm")
        let groundMean = (ground.red + ground.green + ground.blue) / 3
        let skyMean = (sky.red + sky.green + sky.blue) / 3
        #expect(groundMean < skyMean * 0.5, "the ground should be darker than the sky (\(groundMean) vs \(skyMean))")
    }

    @Test("it leaves through the RGB555 dither")
    func quantised() throws {
        guard let frame = try RenderedFrame.make(named: "raster", width: 640, height: 360, time: 5.0) else {
            return
        }
        for channel in 0..<3 {
            let count = levels(of: frame, channel: channel).count
            #expect(count <= 32, "channel \(channel) has \(count) levels")
            #expect(count > 4, "channel \(channel) has collapsed to \(count) levels")
        }
    }
}
