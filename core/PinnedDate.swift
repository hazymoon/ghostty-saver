import Foundation

/// The value `--date` accepts, so a shader that reads iDate can be rendered
/// at the same instant twice.
///
/// Two forms: an ISO 8601 instant (`2026-08-28T21:30:00Z`, with or without
/// fractional seconds, any offset), or a bare number of seconds since local
/// midnight today. The second is the short way to ask for "dusk" without
/// caring about the calendar date.
public enum PinnedDate {
    public static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let seconds = Double(trimmed), seconds.isFinite, seconds >= 0 {
            let midnight = Calendar.current.startOfDay(for: Date())
            return midnight.addingTimeInterval(seconds)
        }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: trimmed) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }
}
