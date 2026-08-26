import Foundation

/// 秒単位のサンプル列を集計してミリ秒で報告する。
struct Samples {
    private(set) var values: [Double] = []

    mutating func append(_ seconds: Double) { values.append(seconds) }

    var count: Int { values.count }
    var sum: Double { values.reduce(0, +) }
    var mean: Double { values.isEmpty ? 0 : sum / Double(values.count) }

    func percentile(_ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[index]
    }

    /// "mean 1.23 / p50 1.10 / p95 2.40 / max 5.00 ms" 形式
    func summaryMilliseconds() -> String {
        func ms(_ v: Double) -> String { String(format: "%6.3f", v * 1000) }
        return "mean \(ms(mean))  p50 \(ms(percentile(0.5)))  p95 \(ms(percentile(0.95)))  max \(ms(percentile(1.0)))"
    }
}
