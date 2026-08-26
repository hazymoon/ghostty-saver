import Foundation

/// Collects a series of durations in seconds and reports them in milliseconds.
public struct Samples {
    public private(set) var values: [Double] = []

    public init() {}

    public mutating func append(_ seconds: Double) { values.append(seconds) }

    public var count: Int { values.count }
    public var sum: Double { values.reduce(0, +) }
    public var mean: Double { values.isEmpty ? 0 : sum / Double(values.count) }

    public func percentile(_ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[index]
    }

    /// Formats as "mean 1.230  p50 1.100  p95 2.400  max 5.000".
    public func summaryMilliseconds() -> String {
        func ms(_ value: Double) -> String { String(format: "%6.3f", value * 1000) }
        return "mean \(ms(mean))  p50 \(ms(percentile(0.5)))  p95 \(ms(percentile(0.95)))  max \(ms(percentile(1.0)))"
    }
}
