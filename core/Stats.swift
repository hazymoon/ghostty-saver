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
    /// Logarithmic buckets, so the resolution is relative rather than
    /// absolute. Linear buckets sized for a 10 ms frame collapse everything
    /// below one bucket to the same value, which made a 0.011 ms mean report a
    /// 0.025 ms median. These hold every value to within 2 percent from a
    /// microsecond to ten seconds, in fewer than a thousand buckets.
    private static let smallestSeconds = 0.000_001
    private static let growthPerBucket = 1.02
    private static let bucketCount = 815

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

        guard seconds > Self.smallestSeconds else {
            buckets[0] += 1
            return
        }
        let index = Int(log(seconds / Self.smallestSeconds) / log(Self.growthPerBucket))
        if index < Self.bucketCount {
            buckets[index] += 1
        } else {
            beyondRange += 1
        }
    }

    /// The histogram never grows, whatever is appended. Exposed so a test can
    /// assert that rather than inferring it from process memory.
    var histogramStorageCount: Int { buckets.count }

    public var mean: Double { count == 0 ? 0 : sum / Double(count) }

    /// Accurate to 2 percent. A percentile of 1 returns the exact maximum.
    public func percentile(_ p: Double) -> Double {
        guard count > 0 else { return 0 }
        if p >= 1 { return maximum }

        let target = Int((Double(count - 1) * p).rounded())
        var seen = 0
        for (index, bucket) in buckets.enumerated() where bucket > 0 {
            seen += bucket
            if seen > target {
                // Geometric midpoint, since the bucket is a ratio not a span.
                // Clamped to the maximum: a cluster sitting in the lower half
                // of its bucket would otherwise report a percentile above
                // anything actually measured, and the summary line would read
                // "p50 0.993  max 0.984".
                let lower = Self.smallestSeconds * pow(Self.growthPerBucket, Double(index))
                return min(lower * sqrt(Self.growthPerBucket), maximum)
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
