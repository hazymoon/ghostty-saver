import Foundation
import Metal
import Testing

@testable import SaverCore

/// The contour map is line work: bright contour lines and a hatched ground on
/// a dark field. Loose on purpose, to catch it turning into a fill or going
/// out, not to pin a look.
@Suite("contour shader")
struct ContourShaderTests {
    @Test("ink lines on a dark ground")
    func inkOnDark() throws {
        guard let frame = try RenderedFrame.make(named: "contour", width: 640, height: 360, time: 6.5) else {
            return
        }
        #expect(frame.peak() > 150, "the contour lines should be bright ink")
        #expect(frame.brightness() < 80, "the ground should stay dark (mean \(frame.brightness()))")
        let lit = frame.litFraction(threshold: 96)
        #expect(lit > 0.01, "nothing is being drawn (lit fraction \(lit))")
        #expect(lit < 0.45, "this is meant to be line work, not a fill (lit fraction \(lit))")
    }

    /// Both the contour width and the hatch spacing are counted in pixels, so
    /// the share of the frame under ink should be of the same order at any
    /// resolution; a width counted in screen heights would make the small
    /// frame far heavier.
    @Test("line weight holds across resolutions")
    func weightHolds() throws {
        guard let small = try RenderedFrame.make(named: "contour", width: 320, height: 240, time: 6.5),
              let large = try RenderedFrame.make(named: "contour", width: 1920, height: 1080, time: 6.5) else {
            return
        }
        let smallLit = small.litFraction(threshold: 96)
        let largeLit = large.litFraction(threshold: 96)
        #expect(smallLit > 0.005 && largeLit > 0.005, "one of the frames is empty")
        let ratio = smallLit / largeLit
        #expect(ratio > 0.4 && ratio < 2.5,
                "lit fraction \(smallLit) at 320x240 against \(largeLit) at 1920x1080")
    }
}
