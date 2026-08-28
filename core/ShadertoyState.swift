import Foundation
import GeneratedShaders
import Metal

/// Keeps Ghostty's uniform block up to date, one write per frame.
///
/// The offsets come from `ShadertoyUniformLayout` in Generated/Shaders.swift,
/// which is derived from spirv-cross reflection, so this only has to name them.
///
/// Cursor, palette and foreground/background colors mean nothing here because
/// there is no terminal state to report, so they stay zero. The same .glsl
/// running under Ghostty gets the real values from Ghostty.
public struct ShadertoyState {
    public let uniforms: UniformBuffer

    private var width: Float
    private var height: Float
    private var previousTime: Float = 0

    public init?(device: MTLDevice, width: Int, height: Int) {
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

    /// Adopts a new render size after the terminal was resized.
    public mutating func setResolution(width newWidth: Int, height newHeight: Int) {
        width = Float(newWidth)
        height = Float(newHeight)
        uniforms.set(width, height, 1, at: ShadertoyUniformLayout.iResolution)
    }

    /// Writes the per-frame members. The clock is handed in rather than read
    /// here so that a caller can pin it: `--date` on the command line and the
    /// test suite both need the same iDate on two renders, which an ambient
    /// `Date()` cannot give.
    public mutating func update(time: Float, frame: Int, frameRate: Float, date now: Date) {
        uniforms.set(time, at: ShadertoyUniformLayout.iTime)
        uniforms.set(time - previousTime, at: ShadertoyUniformLayout.iTimeDelta)
        uniforms.set(frameRate, at: ShadertoyUniformLayout.iFrameRate)
        uniforms.set(Int32(truncatingIfNeeded: frame), at: ShadertoyUniformLayout.iFrame)
        previousTime = time

        // Shadertoy's iDate is (year, month - 1, day, seconds since midnight).
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
