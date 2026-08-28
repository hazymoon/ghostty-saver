import Foundation
import Metal
import Testing

@testable import SaverCore

/// The moire is bright beat cells where the two lattices' lines land together,
/// set in a dark mesh where they interleave. Loose on purpose: it catches the
/// shader turning into a flat wash or a white screen, not a particular look.
@Suite("moire shader")
struct MoireShaderTests {
    @Test("lattice lines on a dark ground")
    func linesOnDark() throws {
        guard let frame = try RenderedFrame.make(named: "moire", width: 640, height: 360, time: 9.0) else {
            return
        }
        #expect(frame.peak() > 180, "the lines where the lattices coincide should be bright")
        #expect(frame.brightness() < 120, "the ground between the lines should stay dark (mean \(frame.brightness()))")
        let lit = frame.litFraction(threshold: 96)
        #expect(lit > 0.03, "nothing is being drawn (lit fraction \(lit))")
        #expect(lit < 0.60, "the mesh has filled in (lit fraction \(lit))")
    }

    /// The beat is the point: the same pixel is bright in one part of the
    /// cycle and dark in another as the lattices slide against each other.
    @Test("the beat sweeps the pattern")
    func beatMoves() throws {
        guard let early = try RenderedFrame.make(named: "moire", width: 320, height: 180, time: 3.0),
              let later = try RenderedFrame.make(named: "moire", width: 320, height: 180, time: 13.0) else {
            return
        }
        let moved = early.fractionDiffering(from: later, byMoreThan: 40)
        #expect(moved > 0.10, "the beat has stopped sweeping (\(moved) of the frame changed)")
    }
}
