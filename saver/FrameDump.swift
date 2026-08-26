import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes a rendered frame to a PNG.
///
/// Useful when iterating on a shader: the result can be looked at without a
/// terminal, and a still frame is easier to judge than a moving one.
enum FrameDump {
    static func writePNG(
        pixels: UnsafeRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        to path: String
    ) throws {
        let byteCount = bytesPerRow * height
        let data = Data(bytes: pixels, count: byteCount)

        guard let provider = CGDataProvider(data: data as CFData) else {
            throw FrameDumpError.encodingFailed
        }
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            // The render target is RGBA8 with a trailing alpha channel.
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw FrameDumpError.encodingFailed
        }

        let url = URL(fileURLWithPath: path)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw FrameDumpError.cannotWrite(path)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FrameDumpError.cannotWrite(path)
        }
    }
}

enum FrameDumpError: Error, CustomStringConvertible {
    case encodingFailed
    case cannotWrite(String)

    var description: String {
        switch self {
        case .encodingFailed:
            return "could not build an image from the frame"
        case .cannotWrite(let path):
            return "could not write \(path)"
        }
    }
}
