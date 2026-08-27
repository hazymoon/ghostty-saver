// A small helper for the scripts that look at a terminal window from outside:
// which window belongs to a process, and what a capture of it looks like.
//
// Compiled on demand by the script that needs it (see Scripts/check-repaint.sh),
// because neither question can be answered from a shell. Window ids come from
// the window server, and a screenshot has to be decoded to say whether it is
// showing a shader or a prompt.
//
// Usage:
//   window-probe window <pid>        prints "id=N x=.. y=.. w=.. h=.. onscreen=0|1",
//                                    one line per ordinary window owned by the
//                                    process, largest first; exit 1 if it has none
//   window-probe frontmost <pid>     exit 0 if a window of the process is the
//                                    frontmost window on screen, 1 otherwise
//   window-probe look <png>          prints "brightness=.. saturation=.." over
//                                    the whole image, both 0-255

import CoreGraphics
import Foundation
import ImageIO

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("window-probe: \(message)\n".utf8))
    exit(2)
}

/// Windows on screen, front to back, as the window server lists them.
func windows(ownedBy pid: Int32) -> [(id: CGWindowID, bounds: CGRect, layer: Int, onscreen: Bool)] {
    guard let list = CGWindowListCopyWindowInfo(
        [.optionAll, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] else { return [] }

    return list.compactMap { info in
        guard let owner = info[kCGWindowOwnerPID as String] as? Int32, owner == pid,
              let id = info[kCGWindowNumber as String] as? UInt32,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict)
        else { return nil }
        let layer = info[kCGWindowLayer as String] as? Int ?? 0
        let onscreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
        return (CGWindowID(id), bounds, layer, onscreen)
    }
}

func window(pid: Int32) {
    // Layer 0 is the ordinary window layer; anything else is a menu, a
    // tooltip or the like, and those are small anyway.
    // All of them, because which one can be captured is for the caller to
    // find out: a window mid-way into or out of a fullscreen Space is listed
    // at full size and cannot be read.
    let candidates = windows(ownedBy: pid)
        .filter { $0.layer == 0 }
        .sorted { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }
    guard !candidates.isEmpty else { exit(1) }
    for window in candidates {
        print("id=\(window.id) x=\(Int(window.bounds.minX)) y=\(Int(window.bounds.minY)) "
            + "w=\(Int(window.bounds.width)) h=\(Int(window.bounds.height)) onscreen=\(window.onscreen ? 1 : 0)")
    }
}

func frontmost(pid: Int32) {
    // The on-screen list is ordered front to back; the first ordinary window
    // in it is what the user sees on top.
    guard let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] else { exit(1) }
    for info in list {
        guard (info[kCGWindowLayer as String] as? Int ?? 0) == 0 else { continue }
        let owner = info[kCGWindowOwnerPID as String] as? Int32 ?? -1
        exit(owner == pid ? 0 : 1)
    }
    exit(1)
}

func look(path: String) {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fail("could not decode \(path)") }

    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { fail("\(path) is empty") }

    // Redraw into a known RGBA layout rather than trusting the file's.
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
    guard let context = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("could not draw \(path)") }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var brightness = 0.0
    var saturation = 0.0
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * bytesPerRow + x * 4
            let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
            let high = max(r, max(g, b)), low = min(r, min(g, b))
            brightness += Double(r + g + b) / 3
            // Chroma rather than HSV saturation: a dark blue prompt background
            // has full HSV saturation and no visible colour at all.
            saturation += Double(high - low)
        }
    }
    let count = Double(width * height)
    print(String(format: "brightness=%.1f saturation=%.1f", brightness / count, saturation / count))
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "window" where arguments.count == 2:
    guard let pid = Int32(arguments[1]) else { fail("bad pid \(arguments[1])") }
    window(pid: pid)
case "frontmost" where arguments.count == 2:
    guard let pid = Int32(arguments[1]) else { fail("bad pid \(arguments[1])") }
    frontmost(pid: pid)
case "look" where arguments.count == 2:
    look(path: arguments[1])
default:
    fail("usage: window-probe window <pid> | frontmost <pid> | look <png>")
}
