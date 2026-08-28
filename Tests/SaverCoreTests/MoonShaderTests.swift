import Foundation
import Metal
import Testing

@testable import SaverCore

/// The moon reads iDate, so what it draws is a function of the calendar as
/// much as of iTime. These pin dates on either side of the cycle and ask for
/// the things a phase has to get right, loosely.
@Suite("moon shader")
struct MoonShaderTests {
    private static func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    // 2026-01-03 is a full moon; 2026-01-18 evening is new; the 15th and the
    // 22nd are a week apart, waning crescent and waxing crescent.
    private static let full = date("2026-01-03T10:00:00Z")
    private static let new = date("2026-01-18T20:00:00Z")
    private static let waning = date("2026-01-15T12:00:00Z")
    private static let waxing = date("2026-01-22T12:00:00Z")

    @Test("a full moon is a bright, neutral disc on a dark sky")
    func fullMoonIsBright() throws {
        guard let frame = try RenderedFrame.make(named: "moon", width: 640, height: 360, time: 6.5, date: Self.full) else {
            return
        }
        #expect(frame.peak() > 200, "the disc should be bright")
        let lit = frame.litFraction(threshold: 100)
        #expect(lit > 0.10, "the disc has gone (lit fraction \(lit))")
        #expect(lit < 0.45, "the disc has swallowed the sky (lit fraction \(lit))")
        let means = frame.channelMeans()
        #expect(abs(means.red - means.blue) < means.green * 0.25, "the moon should be grey, not coloured")
    }

    /// The crescent case the issue warns about: with the sunlit part gone,
    /// earthshine and the stars still have to leave something to see.
    @Test("a new moon is dark but not nothing", arguments: [(320, 240), (1280, 720)])
    func newMoonIsDarkButPresent(width: Int, height: Int) throws {
        guard let frame = try RenderedFrame.make(named: "moon", width: width, height: height, time: 6.5, date: Self.new),
              let full = try RenderedFrame.make(named: "moon", width: width, height: height, time: 6.5, date: Self.full) else {
            return
        }
        #expect(frame.peak() > 40, "the new moon drew nothing to speak of at \(width)x\(height)")
        #expect(frame.brightness() < full.brightness() / 4, "a new moon should be far darker than a full one")
    }

    @Test("a week changes the phase")
    func phaseMovesWithTheCalendar() throws {
        guard let first = try RenderedFrame.make(named: "moon", width: 320, height: 240, time: 6.5, date: Self.waning),
              let second = try RenderedFrame.make(named: "moon", width: 320, height: 240, time: 6.5, date: Self.waxing) else {
            return
        }
        let moved = first.fractionDiffering(from: second, byMoreThan: 8)
        #expect(moved > 0.02, "the same picture a week apart (\(moved) of the frame moved)")
        // Waning is lit on the left, waxing on the right.
        #expect(litSide(first) < 0, "a waning crescent should be lit on the left")
        #expect(litSide(second) > 0, "a waxing crescent should be lit on the right")
    }

    /// Positive when the right half is brighter than the left.
    private func litSide(_ frame: RenderedFrame) -> Double {
        var left = 0.0, right = 0.0
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let value = Double(frame.pixels[y * frame.bytesPerRow + x * 4 + 1])
                if x < frame.width / 2 { left += value } else { right += value }
            }
        }
        return right - left
    }
}
