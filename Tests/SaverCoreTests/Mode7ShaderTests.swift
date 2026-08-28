import Testing

@testable import SaverCore

@Suite("mode7 shader")
struct Mode7ShaderTests {
    /// A blue sky over a warm floor: the horizon splits the frame, and the
    /// two halves have to stay different things.
    @Test("the floor is warm under a cool sky")
    func floorUnderSky() throws {
        guard let frame = try RenderedFrame.make(named: "mode7", width: 640, height: 360, time: 6.5) else {
            return
        }
        let sky = frame.channelMeans(rows: 0..<(frame.height / 4))
        let floor = frame.channelMeans(rows: (frame.height * 2 / 3)..<frame.height)
        #expect(sky.blue > sky.red * 1.5, "the sky should be blue")
        #expect(floor.red > floor.blue * 1.3, "the floor should be warm")
    }

    /// The floor is a checker, so it has to carry contrast rather than be a
    /// flat wash - and stay one at every size.
    @Test("the floor keeps its checker at every resolution", arguments: [
        (320, 240), (1280, 720),
    ])
    func floorHasContrast(width: Int, height: Int) throws {
        guard let frame = try RenderedFrame.make(named: "mode7", width: width, height: height, time: 27.0) else {
            return
        }
        var lightest = 0
        var darkest = 255
        for y in (frame.height * 3 / 4)..<frame.height {
            for x in 0..<frame.width {
                let red = Int(frame.pixels[y * frame.bytesPerRow + x * 4])
                lightest = max(lightest, red)
                darkest = min(darkest, red)
            }
        }
        #expect(lightest - darkest > 40, "the near floor is a flat wash (\(darkest)..\(lightest))")
    }
}
