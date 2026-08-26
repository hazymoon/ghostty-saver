import Foundation
import Metal
import SaverCore

// 段階2: Metal オフスクリーン。
// 共有メモリ上に直接レンダーターゲットを置き、GPU の描画結果をそのまま
// kitty graphics protocol で送る。シェーダは段階2b で GLSL から生成したものに
// 差し替わるため、ここでは繋ぎのグラデーションを埋め込んでいる。

// MARK: - 繋ぎのシェーダ

/// 段階2b で `shaders/*.glsl` から生成した MSL に置き換わる。
let placeholderFragmentSource = """
struct SaverUniforms {
    float2 resolution;
    float time;
    int frame;
};

fragment float4 saver_fragment(
    SaverVertexOut in [[stage_in]],
    constant SaverUniforms &uniforms [[buffer(0)]]
) {
    float2 uv = in.position.xy / uniforms.resolution;
    float pulse = 0.5 + 0.5 * sin(uniforms.time * 2.0);
    return float4(uv.x, uv.y, pulse, 1.0);
}
"""

/// MSL 側の `SaverUniforms` と同じレイアウト（float2 が 0、float が 8、int が 12）。
struct SaverUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var frame: Int32
}

// MARK: - オプション

struct Options {
    var explicitSize: (width: Int, height: Int)?
    var seconds: Double?
    var maxFrames: Int?
    var targetFPS: Double = 60
    var quiet: QuietLevel = .verbose
    var verify = false
    var stats = false
}

let usage = """
使い方: ghostty-saver [オプション]

  --size WxH        端末に問い合わせず解像度を明示する
  --seconds N       N 秒で終了する（既定はキー入力があるまで動き続ける）
  --frames N        N フレームで終了する
  --fps N           目標フレームレート（既定 60、0 で上限なし）
  --quiet-level N   0=応答あり（既定）, 1=エラーのみ, 2=応答なし
  --verify          端末に出さず 1 フレーム描いて共有メモリの中身を検証する
  --stats           終了時に 1 フレームあたりの内訳を出す
  -h, --help        この使い方を表示する
"""

func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())

    func nextValue(_ flag: String) -> String {
        guard !arguments.isEmpty else {
            FileHandle.standardError.write(Data("\(flag) に値がありません\n".utf8))
            exit(2)
        }
        return arguments.removeFirst()
    }

    while !arguments.isEmpty {
        let argument = arguments.removeFirst()
        switch argument {
        case "-h", "--help":
            print(usage)
            exit(0)
        case "--size":
            let value = nextValue(argument)
            let parts = value.lowercased().split(separator: "x")
            guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 else {
                FileHandle.standardError.write(Data("--size は WxH 形式で指定してください: \(value)\n".utf8))
                exit(2)
            }
            options.explicitSize = (w, h)
        case "--seconds":
            options.seconds = Double(nextValue(argument))
        case "--frames":
            options.maxFrames = Int(nextValue(argument))
        case "--fps":
            options.targetFPS = Double(nextValue(argument)) ?? 60
        case "--quiet-level":
            options.quiet = QuietLevel(rawValue: Int(nextValue(argument)) ?? 0) ?? .verbose
        case "--verify":
            options.verify = true
        case "--stats":
            options.stats = true
        default:
            FileHandle.standardError.write(Data("不明なオプション: \(argument)\n\n\(usage)\n".utf8))
            exit(2)
        }
    }
    return options
}

func fail(_ message: String) -> Never {
    TerminalSession.restore()
    FileHandle.standardError.write(Data("ghostty-saver: \(message)\n".utf8))
    exit(1)
}

func report(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

// MARK: - 検証モード

/// 端末を使わず、共有メモリに載った描画結果を直接読んで確認する。
func runVerify(width: Int, height: Int) -> Never {
    prepareShmTracking()
    let renderer: MetalRenderer
    do {
        renderer = try MetalRenderer(
            width: width,
            height: height,
            fragmentSource: placeholderFragmentSource,
            fragmentFunctionName: "saver_fragment"
        )
    } catch {
        fail("\(error)")
    }

    report("デバイス          : \(renderer.device.name)")
    report("要求解像度        : \(width) x \(height)")
    report("実解像度          : \(renderer.width) x \(renderer.height) "
        + "(bytesPerRow=\(renderer.bytesPerRow), linear texture の境界に切り上げ)")

    do {
        let frame = try ShmFrame.create(
            name: makeShmName(pid: getpid(), counter: 0),
            payloadBytes: renderer.payloadBytes
        )
        var uniforms = SaverUniforms(
            resolution: SIMD2<Float>(Float(renderer.width), Float(renderer.height)),
            time: 0,
            frame: 0
        )
        try renderer.render(into: frame) { encoder in
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SaverUniforms>.stride, index: 0)
        }

        // 共有メモリ側を直接読む。GPU の書き込みがそのまま載っているはず。
        let pixels = frame.base.assumingMemoryBound(to: UInt8.self)
        func pixel(_ x: Int, _ y: Int) -> String {
            let offset = y * renderer.bytesPerRow + x * 4
            return "(\(pixels[offset]),\(pixels[offset + 1]),\(pixels[offset + 2]),\(pixels[offset + 3]))"
        }
        report("共有メモリの実データ (RGBA)")
        report("  左上 \(pixel(0, 0))  右上 \(pixel(renderer.width - 1, 0))")
        report("  左下 \(pixel(0, renderer.height - 1))  右下 \(pixel(renderer.width - 1, renderer.height - 1))")
        frame.closeMapping()
    } catch {
        fail("\(error)")
    }

    unlinkTrackedShm()
    exit(0)
}

// MARK: - 起動

let options = parseOptions()

if options.verify {
    let size = options.explicitSize ?? (width: 1920, height: 1080)
    runVerify(width: size.width, height: size.height)
}

let outputIsTTY = TerminalSession.openOutput(sinkPath: nil)
guard outputIsTTY else { fail("端末に接続されていません（検証だけなら --verify を使ってください）") }

let size: TerminalSize
if let explicit = options.explicitSize {
    size = TerminalSize(pixelWidth: explicit.width, pixelHeight: explicit.height, columns: 0, rows: 0)
} else {
    do {
        size = try resolveTerminalSize(fd: TerminalSession.outputFD)
    } catch {
        fail("端末サイズを取得できません: \(error)")
    }
}

let renderer: MetalRenderer
do {
    renderer = try MetalRenderer(
        width: size.pixelWidth,
        height: size.pixelHeight,
        fragmentSource: placeholderFragmentSource,
        fragmentFunctionName: "saver_fragment"
    )
} catch {
    fail("\(error)")
}

TerminalSession.prepare()
TerminalSession.enterRawMode()
TerminalSession.enterAltScreen()
TerminalSession.hideCursor()

let transport = KittySharedMemoryTransport(
    fd: TerminalSession.outputFD,
    width: renderer.width,
    height: renderer.height,
    quiet: options.quiet
)
let reader = ResponseReader(fd: TerminalSession.outputFD)

var renderSamples = Samples()
var shmSamples = Samples()
var writeSamples = Samples()
var ackSamples = Samples()

let frameInterval = options.targetFPS > 0 ? 1 / options.targetFPS : 0
let startedAt = monotonicNow()
var frameIndex: UInt64 = 0
var stopped = false

while !stopped {
    if let maxFrames = options.maxFrames, frameIndex >= UInt64(maxFrames) { break }
    if let seconds = options.seconds, monotonicNow() - startedAt >= seconds { break }

    let frameStart = monotonicNow()

    // 端末は読み終えた shm を自分で unlink するので毎フレーム作り直す。
    let shmStart = monotonicNow()
    let frame: ShmFrame
    do {
        frame = try ShmFrame.create(
            name: makeShmName(pid: getpid(), counter: frameIndex),
            payloadBytes: renderer.payloadBytes
        )
    } catch {
        fail("\(error)")
    }
    shmSamples.append(monotonicNow() - shmStart)

    let renderStart = monotonicNow()
    var uniforms = SaverUniforms(
        resolution: SIMD2<Float>(Float(renderer.width), Float(renderer.height)),
        time: Float(frameStart - startedAt),
        frame: Int32(truncatingIfNeeded: frameIndex)
    )
    do {
        try renderer.render(into: frame) { encoder in
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SaverUniforms>.stride, index: 0)
        }
    } catch {
        fail("\(error)")
    }
    renderSamples.append(monotonicNow() - renderStart)

    frame.closeMapping()

    do {
        writeSamples.append(try transport.send(frame: frame))
    } catch {
        fail("\(error)")
    }
    frameIndex += 1

    if options.quiet != .silent {
        let ackStart = monotonicNow()
        switch reader.next(timeout: 2.0) {
        case .response:
            break
        case .userInput:
            stopped = true
        case .timeout:
            TerminalSession.restore()
            report("端末から応答が来ませんでした（frame \(frameIndex)）")
            exit(1)
        }
        ackSamples.append(monotonicNow() - ackStart)
    } else {
        var pfd = pollfd(fd: TerminalSession.outputFD, events: Int16(POLLIN), revents: 0)
        if poll(&pfd, 1, 0) > 0 {
            var discard: UInt8 = 0
            if read(TerminalSession.outputFD, &discard, 1) > 0 { stopped = true }
        }
    }

    // 目標フレームレートに合わせて余った時間を寝る。
    if frameInterval > 0 {
        let remaining = frameInterval - (monotonicNow() - frameStart)
        if remaining > 0 { usleep(useconds_t(remaining * 1_000_000)) }
    }
}

let elapsed = monotonicNow() - startedAt
TerminalSession.restore()

if options.stats {
    report("")
    report("=== 段階2 Metal オフスクリーン ===")
    report("デバイス          : \(renderer.device.name)")
    report("解像度            : \(renderer.width) x \(renderer.height) px "
        + "(端末は \(size.pixelWidth) x \(size.pixelHeight))")
    report("1 フレーム        : \(String(format: "%.2f", Double(renderer.payloadBytes) / 1_048_576)) MiB")
    report("フレーム数        : \(frameIndex)")
    report("経過              : \(String(format: "%.3f", elapsed)) 秒")
    report("実効 fps          : \(String(format: "%.2f", elapsed > 0 ? Double(frameIndex) / elapsed : 0))")
    report("")
    report("1 フレームあたりの内訳 (ms)")
    report("  shm 作成        : \(shmSamples.summaryMilliseconds())")
    report("  GPU 描画        : \(renderSamples.summaryMilliseconds())")
    report("  write(2)        : \(writeSamples.summaryMilliseconds())")
    if ackSamples.count > 0 {
        report("  端末応答待ち    : \(ackSamples.summaryMilliseconds())")
    }
}
