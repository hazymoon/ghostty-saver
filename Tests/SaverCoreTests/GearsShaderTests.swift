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

    /// The driven wheels' angles are derived from their driver's, and a
    /// derivation that wraps per tooth makes a wheel jump one tooth every
    /// time its driver's tooth phase rolls over. The teeth survive that; the
    /// windows cut into the larger wheels do not. So: across one millisecond
    /// the picture should change by about as much everywhere in the cycle.
    /// The escapement lands twice a second and moves fast when it does, so
    /// those moments are left out.
    @Test("the driven wheels turn without jumping")
    func drivenWheelsTurnSmoothly() throws {
        var times: [Float] = []
        var time: Float = 6.0
        while time < 9.0 {
            let beat = (time * 2).truncatingRemainder(dividingBy: 1)
            if beat > 0.15, beat < 0.48 {
                times.append(time)
                times.append(time + 0.001)
            }
            time += 0.02
        }
        guard let frames = try RenderedFrame.sequence(named: "gears", width: 320, height: 180, times: times) else {
            return
        }
        var changes: [Double] = []
        for pair in stride(from: 0, to: frames.count, by: 2) {
            changes.append(frames[pair].fractionDiffering(from: frames[pair + 1], byMoreThan: 40))
        }
        let sorted = changes.sorted()
        let median = sorted[sorted.count / 2]
        let largest = sorted[sorted.count - 1]
        #expect(
            largest < 0.001,
            "a wheel jumped: \(largest) of the frame changed in 1 ms against a typical \(median)"
        )
    }
}
