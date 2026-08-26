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

        // Let one-time allocations settle before measuring.
        let base = uniqueCounters(1)[0] * 1000
        try renderFrames(60, from: base)
        let before = residentBytes()

        try renderFrames(5000, from: base + 100)
        let after = residentBytes()

        let growthMB = Double(after &- before) / 1_048_576
        let perFrameBytes = Double(after &- before) / 5000

        let detail = "5000 frames grew the process by \(String(format: "%.2f", growthMB)) MiB "
            + "(\(String(format: "%.0f", perFrameBytes)) bytes per frame)"
        #expect(perFrameBytes < 64, "\(detail)")
    }
}
