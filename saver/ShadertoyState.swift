import Foundation
import GeneratedShaders
import Metal
import SaverCore

/// Ghostty と同じ uniform ブロックを毎フレーム更新する。
///
/// オフセットは Generated/Shaders.swift の `ShadertoyUniformLayout` が
/// spirv-cross のリフレクションから生成しているので、ここでは名前で参照するだけでよい。
///
/// カーソル・パレット・前景/背景色は端末の状態を持たない本プログラムでは意味がないため
/// 0 のままにする。同じ .glsl を Ghostty 側に置いたときはそちらが実際の値を入れる。
struct ShadertoyState {
    let uniforms: UniformBuffer

    private let width: Float
    private let height: Float
    private var previousTime: Float = 0

    init?(device: MTLDevice, width: Int, height: Int) {
        guard let uniforms = UniformBuffer(device: device, byteCount: ShadertoyUniformLayout.size) else {
            return nil
        }
        self.uniforms = uniforms
        self.width = Float(width)
        self.height = Float(height)

        // 解像度と iChannel0（1x1 の黒）の情報は毎フレーム変わらない。
        uniforms.set(self.width, self.height, 1, at: ShadertoyUniformLayout.iResolution)
        uniforms.set(1, 1, 1, at: ShadertoyUniformLayout.iChannelResolution)
        uniforms.set(Int32(0), at: ShadertoyUniformLayout.iCursorVisible)
    }

    mutating func update(time: Float, frame: Int, frameRate: Float) {
        uniforms.set(time, at: ShadertoyUniformLayout.iTime)
        uniforms.set(time - previousTime, at: ShadertoyUniformLayout.iTimeDelta)
        uniforms.set(frameRate, at: ShadertoyUniformLayout.iFrameRate)
        uniforms.set(Int32(truncatingIfNeeded: frame), at: ShadertoyUniformLayout.iFrame)
        previousTime = time

        // Shadertoy の iDate は (年, 月-1, 日, 0 時からの経過秒)
        let now = Date()
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        let midnight = calendar.startOfDay(for: now)
        uniforms.set(
            Float(parts.year ?? 0),
            Float((parts.month ?? 1) - 1),
            Float(parts.day ?? 0),
            Float(now.timeIntervalSince(midnight)),
            at: ShadertoyUniformLayout.iDate
        )
    }
}
