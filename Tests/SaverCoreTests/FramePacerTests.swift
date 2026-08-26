import Foundation
import Testing

@testable import SaverCore

@Suite("frame pacing")
struct FramePacerTests {
    /// Sleeping "the rest of the interval" relative to now loses whatever the
    /// sleep overshot, every frame, forever. This walks a simulated clock that
    /// always overshoots and checks the pacer wins it back.
    @Test("overshooting a sleep does not accumulate")
    func compensatesForOversleep() {
        let target = 60.0
        let interval = 1 / target
        let overshoot = 0.0015   // 1.5ms, typical of usleep

        var pacer = FramePacer(targetFPS: target, now: 0)
        var now = 0.0
        let work = 0.006

        for _ in 0..<600 {
            now += work
            let wait = pacer.sleepInterval(now: now)
            now += wait > 0 ? wait + overshoot : 0
        }

        let averageInterval = now / 600
        #expect(abs(averageInterval - interval) < 0.0002,
                "average frame took \(averageInterval * 1000) ms, wanted \(interval * 1000) ms")
    }

    /// The naive version this replaced: each frame loses the overshoot, so 60
    /// frames a second becomes noticeably fewer. Kept as a check that the test
    /// above is measuring something real.
    @Test("the relative-sleep approach it replaced would drift")
    func naiveApproachDrifts() {
        let interval = 1.0 / 60
        let overshoot = 0.0015
        let work = 0.006

        var now = 0.0
        for _ in 0..<600 {
            let frameStart = now
            now += work
            let remaining = interval - (now - frameStart)
            if remaining > 0 { now += remaining + overshoot }
        }

        let averageInterval = now / 600
        #expect(averageInterval > interval + 0.001, "the naive version should drift")
    }

    @Test("a target of zero never sleeps")
    func uncapped() {
        var pacer = FramePacer(targetFPS: 0, now: 0)
        #expect(pacer.interval == 0)
        #expect(pacer.sleepInterval(now: 0) == 0)
        #expect(pacer.sleepInterval(now: 100) == 0)
    }

    @Test("a frame that took longer than the interval does not sleep")
    func slowFrameDoesNotSleep() {
        var pacer = FramePacer(targetFPS: 60, now: 0)
        #expect(pacer.sleepInterval(now: 0.020) == 0)
    }

    /// Falling far behind must not queue up a run of catch-up frames with no
    /// sleep at all, which would spin the GPU flat out until it caught up.
    @Test("falling far behind resyncs instead of catching up")
    func resyncsWhenFarBehind() {
        let interval = 1.0 / 60
        var pacer = FramePacer(targetFPS: 60, now: 0)

        // A one second stall, e.g. the terminal was busy.
        #expect(pacer.sleepInterval(now: 1.0) == 0)

        // The next frame is on time again rather than being told to skip.
        let wait = pacer.sleepInterval(now: 1.0 + 0.001)
        #expect(wait > 0)
        #expect(wait <= interval)
    }

    @Test("with instant frames the interval is exactly the target")
    func exactPacingWithInstantFrames() {
        let interval = 1.0 / 30
        var pacer = FramePacer(targetFPS: 30, now: 0)
        var now = 0.0

        for frame in 1...100 {
            now += pacer.sleepInterval(now: now)
            #expect(abs(now - Double(frame) * interval) < 1e-9)
        }
    }
}
