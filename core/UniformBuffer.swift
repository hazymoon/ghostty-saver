import Foundation
import Metal

/// Backing store for the uniform block handed to the fragment shader.
///
/// Member names and offsets do not live here. Generated/Shaders.swift derives
/// `ShadertoyUniformLayout` from spirv-cross reflection, and callers use those
/// constants to write into this buffer.
///
/// setFragmentBytes only accepts 4KB and the uniform block is larger, so the
/// data lives in a resident MTLBuffer bound with setFragmentBuffer.
public final class UniformBuffer {
    public let buffer: MTLBuffer
    private let base: UnsafeMutableRawPointer
    private let byteCount: Int

    public init?(device: MTLDevice, byteCount: Int) {
        // Round up to 16 bytes so a trailing vec3 is still fully addressable.
        let rounded = (byteCount + 15) / 16 * 16
        guard let buffer = device.makeBuffer(length: rounded, options: .storageModeShared) else {
            return nil
        }
        self.buffer = buffer
        self.base = buffer.contents()
        self.byteCount = rounded
        memset(base, 0, rounded)
    }

    @inline(__always)
    private func store<T>(_ value: T, at offset: Int) {
        precondition(
            offset >= 0 && offset + MemoryLayout<T>.size <= byteCount,
            "uniform write runs past the end of the buffer (offset=\(offset))"
        )
        base.advanced(by: offset).storeBytes(of: value, as: T.self)
    }

    public func set(_ value: Float, at offset: Int) { store(value, at: offset) }

    public func set(_ value: Int32, at offset: Int) { store(value, at: offset) }

    /// A std140 vec3. Only three components are written, since the next member
    /// may pack into the fourth slot.
    public func set(_ x: Float, _ y: Float, _ z: Float, at offset: Int) {
        store(x, at: offset)
        store(y, at: offset + 4)
        store(z, at: offset + 8)
    }

    public func set(_ x: Float, _ y: Float, _ z: Float, _ w: Float, at offset: Int) {
        store(SIMD4<Float>(x, y, z, w), at: offset)
    }
}
