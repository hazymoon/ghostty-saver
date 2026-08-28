import Foundation
import Metal
import Testing

@testable import SaverCore

/// The shader is dark glass with a few lit drops on it, so it has to stay
/// mostly dark while the drops and the lights behind them keep some colour.
@Suite("raindrops shader")
struct RaindropsShaderTests {
    @Test("the window is dark with lights behind it")
    func darkWithLights() throws {
        guard let frame = try RenderedFrame.make(named: "raindrops", width: 640, height: 360, time: 20.0) else {
            return
        }
        #expect(frame.brightness() < 60, "the glass should be dark (mean \(frame.brightness()))")
        #expect(frame.peak() > 120, "the drops and the lights should still be lit")
        // The bokeh is warm sodium and signage more than it is neon.
        let means = frame.channelMeans()
        #expect(means.red > means.blue, "the city lights should read warm")
    }

    /// A drop moves down its column, so its trail keeps changing where it is.
    @Test("the drops keep running")
    func dropsRun() throws {
        guard let first = try RenderedFrame.make(named: "raindrops", width: 320, height: 240, time: 10.0),
              let second = try RenderedFrame.make(named: "raindrops", width: 320, height: 240, time: 12.0) else {
            return
        }
        let moved = first.fractionDiffering(from: second, byMoreThan: 8)
        #expect(moved > 0.005, "nothing moved in two seconds (\(moved) of the frame)")
        #expect(moved < 0.5, "the whole frame changed, which is not what running drops look like (\(moved))")
    }
}
