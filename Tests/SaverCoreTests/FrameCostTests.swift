import Foundation
import GeneratedShaders
import Metal
import Testing

@testable import SaverCore

/// The size the frame-time work is quoted at: full screen on a 4K display,
/// below the menu bar, which is what `docs/frame-times.md` measures.
private let defaultSize = (width: 3832, height: 2152)

/// Frames thrown away before timing starts, and frames timed after that. The
/// first renders through a fresh pipeline are not what a running screensaver
/// costs, and one frame of a shader is not what the shader costs either.
private let warmUpFrames = 24
private let timedFrames = 120

/// Seconds of `iTime` the timed frames are spread over. A shader whose cost
/// moves with what it is drawing - `backrooms` is dark for a fifth of its lap
/// and stands still twice in it - averages to something honest only if the
/// samples are spread over its cycle rather than taken at one moment.
private let defaultSpan = 150.0

/// `WxH`, as `--size` takes it.
private func parseSize(_ text: String) -> (width: Int, height: Int)? {
    let parts = text.split(separator: "x", maxSplits: 1)
    guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 else {
        return nil
    }
    return (w, h)
}

/// What a shader costs on the GPU, without a terminal and without a window.
///
/// `Scripts/measure-frame-times.sh` is the measurement to design against, and
/// it needs a visible, frontmost Ghostty window and the machine left alone for
/// as long as the run takes - which is not a thing to do after every edit to a
/// shader, and cannot be done at all while working. This is the other number
/// `docs/frame-times.md` describes: the same render, with nothing compositing
/// beside it, from `swift test`.
///
/// It is off unless asked for, because it is slow and because a timing on a
/// machine that is busy is worse than no timing:
///
/// ```sh
/// GHOSTTY_SAVER_TIME=backrooms swift test 2>&1 | grep 'frame cost'
/// GHOSTTY_SAVER_TIME=all GHOSTTY_SAVER_TIME_SIZE=1920x1080 swift test
/// ```
///
/// `GHOSTTY_SAVER_TIME_SPAN` moves the seconds of `iTime` the samples are
/// spread over. The numbers are comparable with each other - one branch
/// against another on the same machine, which is what a change to a shader
/// needs - and not with the window's, which include the compositor and are
/// roughly half as fast again. Read the p95 rather than the mean: a shader
/// whose average fits the budget still drops frames if its slow ones do not,
/// and the mean is the one a stray scheduling gap moves.
@Suite("shader frame cost", .serialized)
struct FrameCostTests {
    @Test("what each named shader costs on the GPU")
    func timeNamedShaders() throws {
        guard let asked = ProcessInfo.processInfo.environment["GHOSTTY_SAVER_TIME"] else { return }
        guard MTLCreateSystemDefaultDevice() != nil else { return }

        let environment = ProcessInfo.processInfo.environment
        let size = environment["GHOSTTY_SAVER_TIME_SIZE"].flatMap(parseSize) ?? defaultSize
        let span = environment["GHOSTTY_SAVER_TIME_SPAN"].flatMap(Double.init) ?? defaultSpan
        let names =
            asked == "all"
            ? GeneratedShaders.all.map(\.name)
            : asked.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }

        shmExclusive.lock()
        defer { shmExclusive.unlock() }
        prepareShmTracking()

        print("frame cost: \(size.width) x \(size.height), \(timedFrames) frames over \(span) s")
        print("| shader | mean | p50 | p95 | min |")
        print("| --- | ---: | ---: | ---: | ---: |")
        for name in names {
            let program = try #require(
                GeneratedShaders.all.first { $0.name == name },
                "no shader named \(name)"
            )
            let milliseconds = try time(program, width: size.width, height: size.height, span: span)
            let mean = milliseconds.reduce(0, +) / Double(milliseconds.count)
            let sorted = milliseconds.sorted()
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            print(
                "| \(name)"
                    + " | \(String(format: "%.2f", mean))"
                    + " | \(String(format: "%.2f", sorted[sorted.count / 2]))"
                    + " | \(String(format: "%.2f", p95))"
                    + " | \(String(format: "%.2f", sorted[0])) |"
            )
        }
    }

    /// Milliseconds for each timed frame of `program`, warm-up discarded.
    ///
    /// One shared memory frame is reused throughout: creating one per render
    /// would time the allocator as much as the GPU, and `render` waits for the
    /// command buffer, so the wall clock across it is the frame.
    private func time(
        _ program: ShaderProgram, width: Int, height: Int, span: Double
    ) throws -> [Double] {
        let renderer = try MetalRenderer(
            width: width,
            height: height,
            fragmentSource: program.source,
            fragmentFunctionName: program.entryPoint
        )
        var state = try #require(
            ShadertoyState(device: renderer.device, width: renderer.width, height: renderer.height)
        )
        let frame = try ShmFrame.create(
            name: makeShmName(pid: getpid(), counter: uniqueCounters(1)[0]),
            payloadBytes: renderer.payloadBytes
        )
        defer {
            frame.closeMapping()
            frame.unlink()
        }

        var milliseconds: [Double] = []
        let total = warmUpFrames + timedFrames
        for index in 0..<total {
            let at = Float(span) * Float(index) / Float(total)
            state.update(time: at, frame: index, frameRate: 60, date: Date())
            let start = Date()
            try renderer.render(into: frame, uniforms: state.uniforms)
            let elapsed = Date().timeIntervalSince(start) * 1000
            if index >= warmUpFrames { milliseconds.append(elapsed) }
        }
        return milliseconds
    }
}
