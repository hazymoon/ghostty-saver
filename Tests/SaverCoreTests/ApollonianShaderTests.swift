import Foundation
import Testing

@testable import SaverCore

@Suite("apollonian shader")
struct ApollonianShaderTests {
    /// The gasket is line work: bright outlines over a dark ground, not a fill.
    @Test("it draws thin bright circles on a dark ground")
    func drawsLines() throws {
        guard let frame = try RenderedFrame.make(named: "apollonian", width: 640, height: 360, time: 6.0) else {
            return
        }
        #expect(frame.peak() > 180, "the outlines should be bright")
        let lit = frame.litFraction(threshold: 96)
        #expect(lit > 0.005, "nothing is being drawn (lit fraction \(lit))")
        #expect(lit < 0.25, "these are meant to be lines, not fills (lit fraction \(lit))")
        #expect(frame.brightness() < 70, "the ground between the circles should be dark")
    }

    /// The loop wraps where `fract(iTime / CYCLE)` does, so the only place a
    /// seam can show is across that wrap. Two frames straddling it should
    /// differ no more than two frames the same distance apart mid-cycle: the
    /// picture keeps moving, but it does not jump.
    @Test("the picture does not jump where the cycle wraps")
    func loopsWithoutASeam() throws {
        let step: Float = 0.005
        guard let beforeWrap = try RenderedFrame.make(named: "apollonian", width: 640, height: 360, time: 24.0 - step),
              let afterWrap = try RenderedFrame.make(named: "apollonian", width: 640, height: 360, time: 24.0 + step),
              let midA = try RenderedFrame.make(named: "apollonian", width: 640, height: 360, time: 12.0 - step),
              let midB = try RenderedFrame.make(named: "apollonian", width: 640, height: 360, time: 12.0 + step),
              let between = try RenderedFrame.make(named: "apollonian", width: 640, height: 360, time: 17.0) else {
            return
        }
        let acrossWrap = beforeWrap.fractionDiffering(from: afterWrap, byMoreThan: 8)
        let midCycle = midA.fractionDiffering(from: midB, byMoreThan: 8)
        #expect(
            acrossWrap < midCycle * 2 + 0.002,
            "the loop has a seam (\(acrossWrap) of the frame changes across the wrap, \(midCycle) mid-cycle)"
        )
        let moved = beforeWrap.fractionDiffering(from: between, byMoreThan: 8)
        #expect(moved > 0.05, "half a cycle apart the picture should have moved (\(moved))")
    }
}
