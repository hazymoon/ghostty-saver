import Foundation
import Metal
import Testing

@testable import SaverCore

/// shaders/lib/palette.glsl answers a role with a colour that depends on the
/// time of day in iDate. The fixture washes its middle with the sky role,
/// so a frame of it is where that is checked.
@Suite("time-of-day palette")
struct PaletteTests {
    /// iDate.w is seconds since local midnight, so the two instants are built
    /// on the local calendar rather than as UTC offsets.
    private func localTime(hour: Int) throws -> Date {
        try #require(Calendar.current.date(
            bySettingHour: hour, minute: 0, second: 0, of: RenderedFrame.pinnedDate
        ))
    }

    @Test("the same time of day renders the same frame")
    func sameTimeSameFrame() throws {
        let noon = try localTime(hour: 12)
        guard let first = try RenderedFrame.make(named: "gradient", width: 256, height: 192, time: 1.0, date: noon),
              let second = try RenderedFrame.make(named: "gradient", width: 256, height: 192, time: 1.0, date: noon) else {
            return
        }
        #expect(first.pixels == second.pixels)
    }

    @Test("noon and midnight are different frames")
    func timeOfDayChangesTheFrame() throws {
        let noon = try localTime(hour: 12)
        let midnight = try localTime(hour: 0)
        guard let day = try RenderedFrame.make(named: "gradient", width: 256, height: 192, time: 1.0, date: noon),
              let night = try RenderedFrame.make(named: "gradient", width: 256, height: 192, time: 1.0, date: midnight) else {
            return
        }
        let moved = day.fractionDiffering(from: night, byMoreThan: 8)
        #expect(moved > 0.02, "only \(moved) of the frame follows the time of day")
        // The wash sits in the middle; the corners are the plain ramps.
        #expect(day.pixels[0..<4] == night.pixels[0..<4], "the top-left corner should not follow the clock")
    }
}
