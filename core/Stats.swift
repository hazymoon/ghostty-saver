import Foundation

/// Collects a series of durations and reports them in milliseconds.
///
/// Backed by a fixed histogram rather than the samples themselves. A
/// screensaver renders for hours, and one Double per frame per series is
/// enough growth to show up in exactly the memory check these numbers exist to
/// support - the measurement should not be what moves the measurement.
///
/// Count, sum, mean and maximum stay exact. Percentiles land within one bucket,
/// which is well inside what a per-frame timing report needs to say.
public struct Samples {
    /// 0.05 ms per bucket, covering up to 100 ms. Anything slower than that is
    /// already a stall rather than a frame time, and the exact maximum is kept
    /// separately.
    private static let bucketSeconds = 0.000_05
    private static let bucketCount = 2000

    private var buckets = [Int](repeating: 0, count: bucketCount)
    private var beyondRange = 0

    public private(set) var count = 0
    public private(set) var sum = 0.0
    public private(set) var maximum = 0.0

    public init() {}

    public mutating func append(_ seconds: Double) {
        count += 1
        sum += seconds
        if seconds > maximum { maximum = seconds }

        let index = Int(seconds / Self.bucketSeconds)
        if index >= 0 && index < Self.bucketCount {
            buckets[index] += 1
        } else {
            beyondRange += 1
        }
    }

    /// The histogram never grows, whatever is appended. Exposed so a test can
    /// assert that rather than inferring it from process memory.
    var histogramStorageCount: Int { buckets.count }

    public var mean: Double { count == 0 ? 0 : sum / Double(count) }

    /// Accurate to one bucket. A percentile of 1 returns the exact maximum.
    public func percentile(_ p: Double) -> Double {
        guard count > 0 else { return 0 }
        if p >= 1 { return maximum }

        let target = Int((Double(count - 1) * p).rounded())
        var seen = 0
        for (index, bucket) in buckets.enumerated() where bucket > 0 {
            seen += bucket
            if seen > target {
                return (Double(index) + 0.5) * Self.bucketSeconds
            }
        }
        // Everything past the histogram's range; the maximum is the only exact
        // thing left to say.
        return maximum
    }

    /// Formats as "mean 1.230  p50 1.100  p95 2.400  max 5.000".
    public func summaryMilliseconds() -> String {
        func ms(_ value: Double) -> String { String(format: "%6.3f", value * 1000) }
        return "mean \(ms(mean))  p50 \(ms(percentile(0.5)))  p95 \(ms(percentile(0.95)))  max \(ms(maximum))"
    }
}
