import Foundation

/// CPU でグラデーションを描く。段階2で Metal のオフスクリーン描画に置き換わる部分で、
/// ここを分けておくことで「転送コスト」と「生成コスト」を計測上分離できる。
struct GradientRenderer {
    let width: Int
    let height: Int
    /// 列ごとの R 値を先に作っておき、ピクセルループから除算を追い出す。
    private let columnRed: [UInt32]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        let denominator = max(width - 1, 1)
        self.columnRed = (0..<width).map { UInt32($0 * 255 / denominator) }
    }

    /// RGBA8（リトルエンディアンで byte0=R, byte1=G, byte2=B, byte3=A）で書き込む。
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
