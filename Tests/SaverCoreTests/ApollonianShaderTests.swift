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

    /// One cycle zooms in by exactly one generation, so a frame and the frame
    /// one cycle later are the same picture. That is what makes the loop
    /// seamless, and it is the property most easily lost by retuning the
    /// zoom or the twist independently.
    @Test("a frame one cycle later is the same frame")
    func loopsWithoutASeam() throws {
        guard let first = try RenderedFrame.make(named: "apollonian", width: 640, height: 360, time: 5.0),
              let later = try RenderedFrame.make(named: "apollonian", width: 640, height: 360, time: 29.0),
              let between = try RenderedFrame.make(named: "apollonian", width: 640, height: 360, time: 17.0) else {
            return
        }
        let seam = first.fractionDiffering(from: later, byMoreThan: 8)
        #expect(seam < 0.001, "the loop has a seam (\(seam) of the frame differs a cycle later)")
        let moved = first.fractionDiffering(from: between, byMoreThan: 8)
        #expect(moved > 0.05, "half a cycle later the picture should have moved (\(moved))")
    }
}
