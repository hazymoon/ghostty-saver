import Foundation

/// Draws a gradient on the CPU. In the real renderer this is replaced by an
/// offscreen Metal pass; keeping it separate lets the measurement split
/// "transfer cost" from "generation cost".
struct GradientRenderer {
    let width: Int
    let height: Int
    /// Precomputed red value per column, to keep division out of the pixel loop.
    private let columnRed: [UInt32]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        let denominator = max(width - 1, 1)
        self.columnRed = (0..<width).map { UInt32($0 * 255 / denominator) }
    }

    /// Writes RGBA8, i.e. little-endian byte0=R, byte1=G, byte2=B, byte3=A.
    func render(into base: UnsafeMutableRawPointer, frame: UInt64) {
        let pixels = base.assumingMemoryBound(to: UInt32.self)
        let blue = UInt32((frame &* 3) & 0xFF) << 16
        let denominator = max(height - 1, 1)

        columnRed.withUnsafeBufferPointer { reds in
            for y in 0..<height {
                let green = UInt32(y * 255 / denominator) << 8
                let rowHead = UInt32(0xFF00_0000) | blue | green
                let rowStart = y * width
                for x in 0..<width {
                    pixels[rowStart + x] = rowHead | reds[x]
                }
            }
        }
    }
}
