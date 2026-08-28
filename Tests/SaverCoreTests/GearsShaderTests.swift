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
    /// windows cut into the larger wheels do not.
    ///
    /// The roll-over is at a known time. Wheel C (36 teeth, windows) is
    /// driven by B (12 teeth), which sits off the driver A at 25 degrees and
    /// turns at -0.875 rad/s; C sits off B at -15 degrees. B's tooth phase
    /// along that bearing is (-15deg - angle_B) * 12 / 2pi with
    /// angle_B = 4.407 - 0.875 t, and it crosses an integer every 0.598 s,
    /// at t = 5.336 + 0.598 k. Two frames a millisecond either side of one
    /// crossing should differ no more than two frames the same distance
    /// apart a moment later. Four frames, because a sweep dense enough to
    /// straddle a 1 ms event by chance is hundreds of frames, and that
    /// takes the CI runner's GPU down with the test process. If the
    /// shader's constants move, this crossing moves with them and the test
    /// goes quiet rather than wrong: keep these numbers in step with
    /// shaders/gears.glsl.
    @Test("the driven wheels turn without jumping")
    func drivenWheelsTurnSmoothly() throws {
        let bearingBC = -15.0 * .pi / 180.0
        let angleB = { (t: Double) in 4.407 - 0.875 * t }
        let phaseC = { (t: Double) in ((bearingBC - angleB(t)) * 12.0 / (2.0 * .pi)).rounded(.down) }
        // k = 3: the first crossing after t = 6 that lands well clear of an
        // escapement tick (ticks every half second; the landing has settled
        // by 0.075 s). Two milliseconds either side, which is wider than the
        // float32 arithmetic in the shader can move the crossing.
        let crossing = 5.336 + 0.5984 * 3
        let half = 0.002
        #expect(phaseC(crossing - half) != phaseC(crossing + half), "the crossing time is miscalculated")
        let beat = (crossing * 2).truncatingRemainder(dividingBy: 1)
        #expect(beat > 0.15 && beat < 0.5, "the crossing sits on an escapement tick (beat \(beat))")

        let control = crossing + 0.05
        guard let frames = try RenderedFrame.sequence(
            named: "gears", width: 320, height: 180,
            times: [Float(crossing - half), Float(crossing + half), Float(control - half), Float(control + half)]
        ) else {
            return
        }
        let acrossCrossing = frames[0].fractionDiffering(from: frames[1], byMoreThan: 40)
        let steady = frames[2].fractionDiffering(from: frames[3], byMoreThan: 40)
        // Relative to the steady change rather than to zero: the CI runner's
        // GPU renders two frames a moment apart a little different
        // everywhere, and a one-tooth jump is a step on top of that.
        #expect(
            acrossCrossing < steady * 2 + 0.001,
            "a wheel jumped at its driver's tooth roll-over: \(acrossCrossing) of the frame changed across the crossing against \(steady) a moment later"
        )
    }
}
