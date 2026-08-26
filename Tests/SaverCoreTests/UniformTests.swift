import Foundation
import GeneratedShaders
import Metal
import Testing

@testable import SaverCore

@Suite("Shadertoy uniforms")
struct UniformTests {
    /// The layout is generated from spirv-cross reflection. These checks exist
    /// so that re-vendoring a newer prefix cannot silently move a member out
    /// from under the writers in ShadertoyState.
    @Test("the generated layout covers every member the shaders rely on")
    func layoutIsComplete() {
        let offsets = [
            ShadertoyUniformLayout.iResolution,
            ShadertoyUniformLayout.iTime,
            ShadertoyUniformLayout.iTimeDelta,
            ShadertoyUniformLayout.iFrameRate,
            ShadertoyUniformLayout.iFrame,
            ShadertoyUniformLayout.iChannelTime,
            ShadertoyUniformLayout.iChannelResolution,
            ShadertoyUniformLayout.iMouse,
            ShadertoyUniformLayout.iDate,
            ShadertoyUniformLayout.iCurrentCursor,
            ShadertoyUniformLayout.iPreviousCursor,
            ShadertoyUniformLayout.iCurrentCursorColor,
            ShadertoyUniformLayout.iPreviousCursorColor,
            ShadertoyUniformLayout.iTimeCursorChange,
        ]
        #expect(offsets.allSatisfy { $0 >= 0 })
        #expect(offsets.allSatisfy { $0 + 4 <= ShadertoyUniformLayout.size })
    }

    /// std140 puts the block at offset zero and packs the first float into the
    /// vec3's fourth slot. Anything else means the prefix or the toolchain
    /// changed shape.
    @Test("the block starts with iResolution followed by iTime")
    func blockStartsWithResolution() {
        #expect(ShadertoyUniformLayout.iResolution == 0)
        #expect(ShadertoyUniformLayout.iTime == 12)
    }

    @Test("the buffer is large enough for the last member")
    func sizeCoversLastMember() {
        let last = ShadertoyUniformLayout.iSelectionBackgroundColor
        #expect(ShadertoyUniformLayout.size >= last + 12)
    }

    @Test("writes land at the offset they were given")
    func writesUseTheGivenOffset() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let buffer = try #require(UniformBuffer(device: device, byteCount: 256))

        buffer.set(Float(1.5), at: 0)
        buffer.set(Int32(7), at: 16)
        buffer.set(Float(1), Float(2), Float(3), at: 32)
        buffer.set(Float(4), Float(5), Float(6), Float(7), at: 48)

        let base = buffer.buffer.contents()
        #expect(base.load(fromByteOffset: 0, as: Float.self) == 1.5)
        #expect(base.load(fromByteOffset: 16, as: Int32.self) == 7)
        #expect(base.load(fromByteOffset: 32, as: Float.self) == 1)
        #expect(base.load(fromByteOffset: 40, as: Float.self) == 3)
        #expect(base.load(fromByteOffset: 60, as: Float.self) == 7)
    }

    /// A vec3 write must not clobber the float that std140 packs into the
    /// fourth slot - iResolution sits directly in front of iTime.
    @Test("a vec3 write leaves the following slot alone")
    func vec3WriteDoesNotOverrun() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let buffer = try #require(UniformBuffer(device: device, byteCount: 64))

        buffer.set(Float(9.5), at: 12)
        buffer.set(Float(1), Float(2), Float(3), at: 0)

        #expect(buffer.buffer.contents().load(fromByteOffset: 12, as: Float.self) == 9.5)
    }

    @Test("the buffer starts zeroed")
    func bufferStartsZeroed() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let buffer = try #require(UniformBuffer(device: device, byteCount: 128))
        let bytes = buffer.buffer.contents().assumingMemoryBound(to: UInt8.self)
        #expect((0..<128).allSatisfy { bytes[$0] == 0 })
    }

    @Test("state writes resolution, time and frame where the shader reads them")
    func stateWritesExpectedFields() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var state = try #require(ShadertoyState(device: device, width: 1920, height: 1080))

        state.update(time: 0.25, frame: 3, frameRate: 60)
        let base = state.uniforms.buffer.contents()

        #expect(base.load(fromByteOffset: ShadertoyUniformLayout.iResolution, as: Float.self) == 1920)
        #expect(base.load(fromByteOffset: ShadertoyUniformLayout.iResolution + 4, as: Float.self) == 1080)
        #expect(base.load(fromByteOffset: ShadertoyUniformLayout.iTime, as: Float.self) == 0.25)
        #expect(base.load(fromByteOffset: ShadertoyUniformLayout.iFrameRate, as: Float.self) == 60)
        #expect(base.load(fromByteOffset: ShadertoyUniformLayout.iFrame, as: Int32.self) == 3)
    }

    @Test("iTimeDelta is the gap since the previous update")
    func timeDeltaTracksPreviousUpdate() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var state = try #require(ShadertoyState(device: device, width: 64, height: 64))

        state.update(time: 1.0, frame: 0, frameRate: 60)
        state.update(time: 1.25, frame: 1, frameRate: 60)

        let delta = state.uniforms.buffer.contents()
            .load(fromByteOffset: ShadertoyUniformLayout.iTimeDelta, as: Float.self)
        #expect(abs(delta - 0.25) < 0.0001)
    }
}

@Suite("sample statistics")
struct SamplesTests {
    /// One bucket of the histogram, which is what percentiles are accurate to.
    private let tolerance = 0.000_05

    @Test("an empty series reports zeroes instead of dividing by zero")
    func emptySeries() {
        let samples = Samples()
        #expect(samples.count == 0)
        #expect(samples.mean == 0)
        #expect(samples.percentile(0.5) == 0)
        #expect(samples.maximum == 0)
    }

    @Test("count, sum, mean and maximum are exact")
    func exactAggregates() {
        var samples = Samples()
        for value in [0.005, 0.001, 0.003, 0.002, 0.004] { samples.append(value) }

        #expect(samples.count == 5)
        #expect(abs(samples.sum - 0.015) < 1e-9)
        #expect(abs(samples.mean - 0.003) < 1e-9)
        #expect(samples.maximum == 0.005)
    }

    @Test("percentiles land within a bucket of the true value")
    func percentilesAreCloseEnough() {
        var samples = Samples()
        for value in [0.005, 0.001, 0.003, 0.002, 0.004] { samples.append(value) }

        #expect(abs(samples.percentile(0.5) - 0.003) <= tolerance)
        #expect(abs(samples.percentile(0) - 0.001) <= tolerance)
        #expect(samples.percentile(1.0) == 0.005)
    }

    @Test("percentiles stay ordered across a wide spread")
    func percentilesAreOrdered() {
        var samples = Samples()
        for index in 0..<1000 { samples.append(Double(index) * 0.000_1) }

        #expect(samples.percentile(0) <= samples.percentile(0.5))
        #expect(samples.percentile(0.5) <= samples.percentile(0.95))
        #expect(samples.percentile(0.95) <= samples.percentile(1.0))
        #expect(abs(samples.percentile(0.5) - 0.05) <= tolerance)
    }

    /// A stall longer than the histogram covers must not be lost or reported
    /// as though it fell in the last bucket.
    @Test("a value past the histogram range is still reported as the maximum")
    func outOfRangeValue() {
        var samples = Samples()
        for _ in 0..<99 { samples.append(0.001) }
        samples.append(5.0)

        #expect(samples.maximum == 5.0)
        #expect(samples.count == 100)
        #expect(abs(samples.percentile(0.5) - 0.001) <= tolerance)
        #expect(samples.summaryMilliseconds().contains("5000.000"))
    }

    /// The point of the histogram: the series does not get bigger as frames go
    /// by. A screensaver appends one of these per frame for hours, and the
    /// previous design kept every sample.
    @Test("storage does not grow with the number of samples")
    func storageIsBounded() {
        var samples = Samples()
        let initialStorage = samples.histogramStorageCount

        for index in 0..<1_000_000 { samples.append(Double(index % 500) * 0.000_1) }

        #expect(samples.count == 1_000_000)
        #expect(samples.histogramStorageCount == initialStorage)
    }
}
