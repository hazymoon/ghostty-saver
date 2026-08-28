import Foundation
import Metal
import Testing

@testable import SaverCore

/// The gear train is an engraving: bright outlines and hatched faces on a
/// dark ground, and it turns. Loose on purpose, to catch it turning into a
/// fill or stopping, not to pin a look.
@Suite("gears shader")
struct GearsShaderTests {
    @Test("ink lines on a dark ground")
    func inkOnDark() throws {
        guard let frame = try RenderedFrame.make(named: "gears", width: 640, height: 360, time: 6.5) else {
            return
        }
        #expect(frame.peak() > 150, "the outlines should be bright ink")
        #expect(frame.brightness() < 80, "the ground should stay dark (mean \(frame.brightness()))")
        let lit = frame.litFraction(threshold: 96)
        #expect(lit > 0.01, "nothing is being drawn (lit fraction \(lit))")
        #expect(lit < 0.40, "this is meant to be line work, not a fill (lit fraction \(lit))")
    }

    /// The driver turns at a fraction of a radian per second and the small
    /// wheels several times faster, so a second apart the teeth have moved.
    @Test("the train turns")
    func trainTurns() throws {
        guard let before = try RenderedFrame.make(named: "gears", width: 640, height: 360, time: 6.0),
              let after = try RenderedFrame.make(named: "gears", width: 640, height: 360, time: 7.0) else {
            return
        }
        let moved = before.fractionDiffering(from: after, byMoreThan: 40)
        #expect(moved > 0.005, "the wheels are not turning (\(moved) of the frame moved)")
    }
}
