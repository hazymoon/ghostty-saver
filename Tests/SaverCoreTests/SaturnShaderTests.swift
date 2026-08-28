import Foundation
import Testing

@testable import SaverCore

@Suite("saturn shader")
struct SaturnShaderTests {
    /// A warm globe and warm rings on a near-black sky: the lit pixels have to
    /// be cream rather than blue, and most of the frame has to stay dark.
    @Test("a warm planet on a dark sky")
    func warmOnDark() throws {
        guard let frame = try RenderedFrame.make(named: "saturn", width: 640, height: 360, time: 6.5) else {
            return
        }
        var totals = (red: 0.0, green: 0.0, blue: 0.0)
        var count = 0.0
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let offset = y * frame.bytesPerRow + x * 4
                guard frame.pixels[offset] > 60 else { continue }
                totals.red += Double(frame.pixels[offset])
                totals.green += Double(frame.pixels[offset + 1])
                totals.blue += Double(frame.pixels[offset + 2])
                count += 1
            }
        }
        let area = Double(frame.width * frame.height)
        #expect(count > area * 0.08, "the planet and rings have gone out (lit \(count / area))")
        #expect(count < area * 0.60, "the sky has gone (lit \(count / area))")
        #expect(totals.red > totals.blue * 1.2, "the lit parts should be warm, not blue")
        #expect(frame.brightness() < 110, "the sky should stay dark (mean \(frame.brightness()))")
    }

    /// The Cassini division is what makes the rings Saturn's: somewhere in the
    /// ring band there must be a dark gap between two bright stretches on the
    /// same row.
    @Test("the rings carry a dark gap")
    func cassiniDivision() throws {
        guard let frame = try RenderedFrame.make(named: "saturn", width: 640, height: 360, time: 6.5) else {
            return
        }
        var rowsWithGap = 0
        for y in 0..<frame.height {
            var brightSeen = false, gapSeen = false, brightAgain = false
            for x in 0..<frame.width {
                let red = frame.pixels[y * frame.bytesPerRow + x * 4]
                if !brightSeen { if red > 90 { brightSeen = true } }
                else if !gapSeen { if red < 35 { gapSeen = true } }
                else if red > 90 { brightAgain = true; break }
            }
            if brightAgain { rowsWithGap += 1 }
        }
        #expect(rowsWithGap > 20, "no row shows bright ring, gap, bright ring (\(rowsWithGap) rows)")
    }
}
