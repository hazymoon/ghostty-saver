import Foundation
import GeneratedShaders
import Metal
import Testing

@testable import SaverCore

/// This process's resident size, in bytes.
func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.resident_size : 0
}

/// A screensaver runs for hours, so anything the frame loop holds on to per
/// frame turns into hundreds of megabytes. Every frame allocates a Metal
/// buffer, a texture, a command buffer and an encoder, and those are
/// Objective-C objects.
@Suite("frame loop memory", .serialized)
struct MemoryGrowthTests {
    @Test("rendering many frames does not grow the process")
    func repeatedRendersDoNotGrow() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        prepareShmTracking()

        let renderer = try MetalRenderer(
            width: 320,
            height: 240,
            fragmentSource: GeneratedShaders.matrix.source,
            fragmentFunctionName: GeneratedShaders.matrix.entryPoint
        )
        var state = try #require(
            ShadertoyState(device: renderer.device, width: renderer.width, height: renderer.height)
        )

        func renderFrames(_ count: Int, from counter: UInt64) throws {
            for index in 0..<count {
                let frame = try ShmFrame.create(
                    name: makeShmName(pid: getpid(), counter: counter + UInt64(index)),
                    payloadBytes: renderer.payloadBytes
                )
                state.update(time: Float(index) / 60, frame: index, frameRate: 60)
                try renderer.render(into: frame, uniforms: state.uniforms)
                frame.closeMapping()
                frame.unlink()
            }
        }

        // Resident size is process-wide and other suites allocate alongside
        // this one, so a single window can pick up someone else's spike. Three
        // windows and the median keeps that from failing the test while still
        // catching growth that happens every frame.
        let framesPerWindow = 2000
        var counter = uniqueCounters(1)[0] * 100_000
        var perFrame: [Double] = []

        // Let one-time allocations settle before measuring.
        try renderFrames(200, from: counter)
        counter += 1000

        for _ in 0..<3 {
            let before = residentBytes()
            try renderFrames(framesPerWindow, from: counter)
            let after = residentBytes()
            counter += UInt64(framesPerWindow) + 1000
            perFrame.append(Double(after &- before) / Double(framesPerWindow))
        }

        let median = perFrame.sorted()[1]
        let detail = "growth per frame across three windows: "
            + perFrame.map { String(format: "%.0f", $0) }.joined(separator: ", ")
            + " bytes (median \(String(format: "%.0f", median)))"
        #expect(median < 64, "\(detail)")
    }
}
