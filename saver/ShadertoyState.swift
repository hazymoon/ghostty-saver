import Foundation
import GeneratedShaders
import Metal
import SaverCore

/// Keeps Ghostty's uniform block up to date, one write per frame.
///
/// The offsets come from `ShadertoyUniformLayout` in Generated/Shaders.swift,
/// which is derived from spirv-cross reflection, so this only has to name them.
///
/// Cursor, palette and foreground/background colors mean nothing here because
/// there is no terminal state to report, so they stay zero. The same .glsl
/// running under Ghostty gets the real values from Ghostty.
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

        // Resolution and the iChannel0 (1x1 black) description never change.
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

        // Shadertoy's iDate is (year, month - 1, day, seconds since midnight).
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
