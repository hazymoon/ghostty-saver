import Foundation
import Metal

/// フラグメントシェーダへ渡す uniform ブロックの実体。
///
/// メンバ名やオフセットはここでは持たない。オフセットは Generated/Shaders.swift の
/// `ShadertoyUniformLayout` が spirv-cross のリフレクションから生成しており、
/// 呼び出し側がそれを使って書き込む。
///
/// `setFragmentBytes` は 4KB までしか渡せず uniform ブロックはそれを超えるため、
/// 常駐の MTLBuffer に持って `setFragmentBuffer` で束ねる。
public final class UniformBuffer {
    public let buffer: MTLBuffer
    private let base: UnsafeMutableRawPointer
    private let byteCount: Int

    public init?(device: MTLDevice, byteCount: Int) {
        // 16 バイト境界に切り上げておく（末尾の vec3 が 16 バイト分読まれても届くように）
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
        precondition(offset >= 0 && offset + MemoryLayout<T>.size <= byteCount,
                     "uniform の書き込みがバッファ外に出ています (offset=\(offset))")
        base.advanced(by: offset).storeBytes(of: value, as: T.self)
    }

    public func set(_ value: Float, at offset: Int) { store(value, at: offset) }

    public func set(_ value: Int32, at offset: Int) { store(value, at: offset) }

    /// std140 の vec3。後続メンバと詰めて並ぶので 3 要素だけ書く。
    public func set(_ x: Float, _ y: Float, _ z: Float, at offset: Int) {
        store(x, at: offset)
        store(y, at: offset + 4)
        store(z, at: offset + 8)
    }

    public func set(_ x: Float, _ y: Float, _ z: Float, _ w: Float, at offset: Int) {
        store(SIMD4<Float>(x, y, z, w), at: offset)
    }
}
