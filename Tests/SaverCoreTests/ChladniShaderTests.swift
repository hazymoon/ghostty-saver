import Testing

@testable import SaverCore

@Suite("chladni shader")
struct ChladniShaderTests {
    /// Sand on a dark plate: pale, warm lines over a screen that is mostly
    /// black. Thick fills or a bright plate would mean the figure is gone.
    @Test("pale sand lines on a dark plate")
    func sandOnDarkPlate() throws {
        guard let frame = try RenderedFrame.make(named: "chladni", width: 640, height: 360, time: 5.0) else {
            return
        }
        #expect(frame.peak() > 180, "the sand should be bright")
        let lit = frame.litFraction(threshold: 96)
        #expect(lit > 0.01, "no nodal lines are being drawn (lit fraction \(lit))")
        #expect(lit < 0.30, "these are meant to be lines, not fills (lit fraction \(lit))")

        let means = frame.channelMeans()
        #expect(means.red > means.blue, "the sand should be warm, not cool")
    }

    /// The figure jumps from one mode to the next rather than morphing, so
    /// two times inside one hold are identical and two across a boundary are
    /// not.
    @Test("modes are held and then hard-cut")
    func modesHardCut() throws {
        guard let early = try RenderedFrame.make(named: "chladni", width: 320, height: 240, time: 0.5),
              let sameHold = try RenderedFrame.make(named: "chladni", width: 320, height: 240, time: 3.0),
              let nextHold = try RenderedFrame.make(named: "chladni", width: 320, height: 240, time: 4.0) else {
            return
        }
        #expect(early.pixels == sameHold.pixels, "a mode should not move while it is held")
        let moved = sameHold.fractionDiffering(from: nextHold, byMoreThan: 8)
        #expect(moved > 0.02, "the plate did not jump to a new mode (\(moved) of the frame)")
    }
}
