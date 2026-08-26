import Foundation

/// Paces the render loop against an absolute deadline.
///
/// Sleeping "whatever is left of the interval" after each frame drifts: the
/// sleep overshoots by a millisecond or so every time, and nothing ever wins
/// that back. At a 60fps target that alone costs several frames a second.
/// Advancing a deadline by exactly one interval makes the next wait shorter by
/// however much the last one overshot, so the error does not accumulate.
public struct FramePacer {
    /// Seconds between frames. Zero means uncapped.
    public let interval: TimeInterval
    private var deadline: TimeInterval

    public init(targetFPS: Double, now: TimeInterval) {
        interval = targetFPS > 0 ? 1 / targetFPS : 0
        deadline = now + interval
    }

    /// How long to sleep before starting the next frame, advancing the
    /// deadline as it goes.
    public mutating func sleepInterval(now: TimeInterval) -> TimeInterval {
        guard interval > 0 else { return 0 }

        let wait = deadline - now
        if wait < -interval {
            // More than a whole frame behind. Resync instead of trying to catch
            // up, which would otherwise mean a burst of zero-length sleeps.
            deadline = now + interval
            return 0
        }

        deadline += interval
        return max(0, wait)
    }
}
