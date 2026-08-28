import Foundation
import GeneratedShaders
import Metal
import Testing

@testable import SaverCore

/// iDate carries the wall clock, and a shader that reads it is only
/// reproducible if the clock can be held still.
@Suite("pinning iDate")
struct DateUniformTests {
    private func dateBytes(_ state: ShadertoyState) -> [Float] {
        let base = state.uniforms.buffer.contents()
        return (0..<4).map { base.load(fromByteOffset: ShadertoyUniformLayout.iDate + $0 * 4, as: Float.self) }
    }

    @Test("the same pinned date writes the same iDate twice")
    func sameDateSameBytes() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var state = try #require(ShadertoyState(device: device, width: 64, height: 64))
        let pinned = Date(timeIntervalSince1970: 1_768_478_400)

        state.update(time: 1.0, frame: 60, frameRate: 60, date: pinned)
        let first = dateBytes(state)
        state.update(time: 2.0, frame: 120, frameRate: 60, date: pinned)
        let second = dateBytes(state)

        #expect(first == second)
    }

    @Test("a different date changes iDate")
    func differentDateDiffers() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var state = try #require(ShadertoyState(device: device, width: 64, height: 64))
        // Local noon today and an hour later, so the calendar day is the same
        // in any zone and only the seconds member moves.
        let noonToday = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)

        state.update(time: 1.0, frame: 60, frameRate: 60, date: noonToday)
        let noon = dateBytes(state)
        state.update(time: 1.0, frame: 60, frameRate: 60, date: noonToday.addingTimeInterval(3600))
        let later = dateBytes(state)

        #expect(noon != later)
        #expect(abs((later[3] - noon[3]) - 3600) < 1)
    }

    @Test("iDate is (year, month - 1, day, seconds since local midnight)")
    func dateComponents() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var state = try #require(ShadertoyState(device: device, width: 64, height: 64))
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: Date())
        let date = midnight.addingTimeInterval(3_723)
        let parts = calendar.dateComponents([.year, .month, .day], from: date)

        state.update(time: 0, frame: 0, frameRate: 60, date: date)
        let bytes = dateBytes(state)

        #expect(bytes[0] == Float(parts.year!))
        #expect(bytes[1] == Float(parts.month! - 1))
        #expect(bytes[2] == Float(parts.day!))
        #expect(abs(bytes[3] - 3_723) < 0.01)
    }
}

@Suite("--date parsing")
struct PinnedDateTests {
    @Test("an ISO 8601 instant")
    func isoInstant() throws {
        let date = try #require(PinnedDate.parse("2026-01-15T12:00:00Z"))
        #expect(date.timeIntervalSince1970 == 1_768_478_400)
    }

    @Test("an ISO 8601 instant with fractional seconds and an offset")
    func isoFractionalWithOffset() throws {
        let date = try #require(PinnedDate.parse("2026-01-15T21:00:00.500+09:00"))
        #expect(date.timeIntervalSince1970 == 1_768_478_400.5)
    }

    @Test("a number is seconds since local midnight today")
    func secondsSinceMidnight() throws {
        let date = try #require(PinnedDate.parse("3600"))
        let midnight = Calendar.current.startOfDay(for: Date())
        #expect(date.timeIntervalSince(midnight) == 3600)
    }

    @Test("anything else is refused")
    func garbage() {
        #expect(PinnedDate.parse("dusk") == nil)
        #expect(PinnedDate.parse("-5") == nil)
        #expect(PinnedDate.parse("") == nil)
    }
}
