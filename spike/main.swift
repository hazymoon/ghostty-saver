import Foundation
import SaverCore

// 段階1: 転送スパイク。
// Metal を使わず CPU で作ったグラデーションを kitty graphics protocol の
// 共有メモリ転送（a=T, t=s）で送り続け、実効 fps と内訳を測る。
//
// 30fps に届かない場合はここで実装を止め、計測値を報告して判断を仰ぐ。

// MARK: - オプション

struct Options {
    var explicitSize: (width: Int, height: Int)?
    var seconds: Double = 5
    var maxFrames: Int?
    var quiet: QuietLevel = .verbose
    var sinkPath: String?
    var useAltScreen = true
    var ackTimeout: Double = 2.0
    /// 最終フレームを表示したままキー入力を待つ（表示確認用）
    var hold = false
    /// 計測せず、応答が来ない原因を切り分ける診断だけを行う
    var probe = false
}

let usage = """
使い方: spike [オプション]

  --size WxH        端末に問い合わせず解像度を明示する（tty が無い環境での計測用）
  --seconds N       計測秒数（既定 5）
  --frames N        フレーム数を指定する。--seconds より優先
  --once            1 フレームだけ送り、キーを押すまで表示したままにする
  --hold            計測後、キーを押すまで最終フレームを表示したままにする
  --quiet-level N   0=応答あり（既定・端末の消化速度で律速）, 1=エラーのみ, 2=応答なし
  --sink PATH       tty ではなく指定パスへ書く（write(2) 以外のコストだけを測る）
  --probe           計測せず診断だけ行う（KGP が届くか / t=d と t=s のどちらが落ちるか）
  --no-alt-screen   代替画面へ切り替えない
  -h, --help        この使い方を表示する

既定の --quiet-level 0 はフレームごとに端末の応答を待つため、
実効 fps が「端末が実際に消化できた速度」になる。
--quiet-level 2 は応答を待たない送信側スループットの上限で、
端末の描画速度とは一致しない。
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
            options.seconds = Double(nextValue(argument)) ?? options.seconds
        case "--frames":
            options.maxFrames = Int(nextValue(argument))
        case "--once":
            options.maxFrames = 1
            options.hold = true
        case "--hold":
            options.hold = true
        case "--quiet-level":
            let value = Int(nextValue(argument)) ?? 0
            options.quiet = QuietLevel(rawValue: value) ?? .verbose
        case "--sink":
            options.sinkPath = nextValue(argument)
        case "--probe":
            options.probe = true
            options.useAltScreen = false
        case "--no-alt-screen":
            options.useAltScreen = false
        default:
            FileHandle.standardError.write(Data("不明なオプション: \(argument)\n\n\(usage)\n".utf8))
            exit(2)
        }
    }
    return options
}

// MARK: - 端末状態の復帰

// シグナルハンドラから触るためグローバルに置く。
var gOutputFD: Int32 = STDOUT_FILENO
var gOriginalTermios = termios()
var gTermiosSaved = false
var gAltScreenEntered = false
var gRestored = false

/// 画像削除 → カーソル表示 → 代替画面終了 → termios 復帰 → shm 回収。
/// atexit / シグナルハンドラ / 正常終了のいずれからでも安全に呼べる。
func restoreTerminal() {
    if gRestored { return }
    gRestored = true

    var sequence = "\u{1b}_Ga=d,d=A\u{1b}\\\u{1b}[?25h"
    if gAltScreenEntered { sequence += "\u{1b}[?1049l" }
    _ = sequence.withCString { write(gOutputFD, $0, strlen($0)) }

    if gTermiosSaved {
        tcsetattr(gOutputFD, TCSANOW, &gOriginalTermios)
    }
    unlinkTrackedShm()
}

func installSignalHandlers() {
    let handler: @convention(c) (Int32) -> Void = { signalNumber in
        restoreTerminal()
        signal(signalNumber, SIG_DFL)
        raise(signalNumber)
    }
    signal(SIGINT, handler)
    signal(SIGTERM, handler)
    signal(SIGHUP, handler)
}

func fail(_ message: String) -> Never {
    restoreTerminal()
    FileHandle.standardError.write(Data("spike: \(message)\n".utf8))
    exit(1)
}

// MARK: - 起動

let options = parseOptions()

// 出力先の決定。stdout がリダイレクトされていても /dev/tty があればそちらを使う。
if let sinkPath = options.sinkPath {
    let fd = open(sinkPath, O_WRONLY)
    guard fd >= 0 else { fail("--sink \(sinkPath) を開けません: \(String(cString: strerror(errno)))") }
    gOutputFD = fd
} else if isatty(STDOUT_FILENO) == 1 {
    gOutputFD = STDOUT_FILENO
} else {
    let fd = open("/dev/tty", O_RDWR)
    gOutputFD = fd >= 0 ? fd : STDOUT_FILENO
}

let outputIsTTY = isatty(gOutputFD) == 1

// tty でなければ応答は読めないので q=2 に落とし、解像度も明示指定が要る。
var quiet = options.quiet
if !outputIsTTY && quiet != .silent {
    quiet = .silent
}

let size: TerminalSize
if let explicit = options.explicitSize {
    size = TerminalSize(pixelWidth: explicit.width, pixelHeight: explicit.height, columns: 0, rows: 0)
} else {
    do {
        size = try resolveTerminalSize(fd: gOutputFD)
    } catch {
        fail("端末サイズを取得できません: \(error)")
    }
}

let width = size.pixelWidth
let height = size.pixelHeight
let payloadBytes = width * height * 4

prepareShmTracking()
installSignalHandlers()
atexit { restoreTerminal() }

if outputIsTTY {
    var raw = termios()
    if tcgetattr(gOutputFD, &raw) == 0 {
        gOriginalTermios = raw
        gTermiosSaved = true
        cfmakeraw(&raw)
        // 1 バイトでも来たら返す。フレームループを止めないため待ち時間は 0。
        raw.c_cc.16 = 1   // VMIN
        raw.c_cc.17 = 0   // VTIME
        tcsetattr(gOutputFD, TCSANOW, &raw)
    }
    if options.useAltScreen {
        _ = "\u{1b}[?1049h".withCString { write(gOutputFD, $0, strlen($0)) }
        gAltScreenEntered = true
    }
    _ = "\u{1b}[?25l".withCString { write(gOutputFD, $0, strlen($0)) }
}

if options.probe {
    guard outputIsTTY else { fail("--probe は tty が必要です") }
    runProbe(fd: gOutputFD, size: size)
    restoreTerminal()
    exit(0)
}

// MARK: - 計測ループ

let transport = KittySharedMemoryTransport(fd: gOutputFD, width: width, height: height, quiet: quiet)
let renderer = GradientRenderer(width: width, height: height)
let reader = outputIsTTY ? ResponseReader(fd: gOutputFD) : nil

var shmCreateSamples = Samples()   // shm_open + ftruncate
var fillSamples = Samples()        // グラデーション書き込み
var unmapSamples = Samples()       // munmap + close
var writeSamples = Samples()       // write(2)
var ackSamples = Samples()         // 端末の応答待ち

let pid = getpid()
var frameCounter: UInt64 = 0
var stoppedByUser = false
var ackFailure: String?
var errorResponses: [String] = []

let loopStart = monotonicNow()
let deadline = loopStart + options.seconds

while true {
    if let maxFrames = options.maxFrames, frameCounter >= UInt64(maxFrames) { break }
    if options.maxFrames == nil && monotonicNow() >= deadline { break }

    // 端末は読み終えた shm を自分で unlink するため、毎フレーム新しい名前で作り直す。
    let name = makeShmName(pid: pid, counter: frameCounter)

    let createStart = monotonicNow()
    let frame: ShmFrame
    do {
        frame = try ShmFrame.create(name: name, payloadBytes: payloadBytes)
    } catch {
        fail("\(error)")
    }
    // create の中で mmap まで済ませているので、内訳は create 全体として計上する。
    let created = monotonicNow()
    shmCreateSamples.append(created - createStart)

    let fillStart = created
    renderer.render(into: frame.base, frame: frameCounter)
    let filled = monotonicNow()
    fillSamples.append(filled - fillStart)

    frame.closeMapping()
    let unmapped = monotonicNow()
    unmapSamples.append(unmapped - filled)

    do {
        writeSamples.append(try transport.send(frame: frame))
    } catch {
        fail("\(error)")
    }

    frameCounter += 1

    // 応答あり（q=0/q=1）なら 1 フレームごとに端末の消化を待つ。
    // これがフレームレートの律速になり、実効 fps が端末側の実力を表す。
    if let reader, quiet != .silent {
        let ackStart = monotonicNow()
        var settled = false
        while !settled {
            switch reader.next(timeout: options.ackTimeout) {
            case .response(let body):
                if !body.hasSuffix("OK") { errorResponses.append(body) }
                settled = true
            case .userInput:
                stoppedByUser = true
                settled = true
            case .timeout:
                ackFailure = "端末から \(options.ackTimeout) 秒以内に応答が来なかった（frame \(frameCounter)）"
                settled = true
            }
        }
        ackSamples.append(monotonicNow() - ackStart)
        if stoppedByUser || ackFailure != nil { break }
    } else if outputIsTTY {
        // 応答なしモードでもキー入力での中断は受け付ける。
        var pfd = pollfd(fd: gOutputFD, events: Int16(POLLIN), revents: 0)
        if poll(&pfd, 1, 0) > 0 {
            var discard: UInt8 = 0
            if read(gOutputFD, &discard, 1) > 0 { stoppedByUser = true; break }
        }
    }
}

let elapsed = monotonicNow() - loopStart

// 後始末は画像削除と代替画面終了を含むので、表示確認したいときはその前で待つ。
if options.hold && outputIsTTY && !stoppedByUser {
    var pfd = pollfd(fd: gOutputFD, events: Int16(POLLIN), revents: 0)
    _ = poll(&pfd, 1, -1)
    var discard: UInt8 = 0
    _ = read(gOutputFD, &discard, 1)
}

restoreTerminal()

// MARK: - 報告

func line(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

let megabytesPerFrame = Double(payloadBytes) / 1_048_576
let fps = elapsed > 0 ? Double(frameCounter) / elapsed : 0

line("")
line("=== 段階1 転送スパイク 計測結果 ===")
line("解像度            : \(width) x \(height) px (\(size.columns) cols x \(size.rows) rows)")
line("1 フレーム        : \(String(format: "%.2f", megabytesPerFrame)) MiB (RGBA8)")
line("応答モード        : q=\(quiet.rawValue) " + (quiet == .silent
    ? "(応答を読まない = 送信側スループットの上限。端末の描画速度ではない)"
    : "(フレームごとに端末の応答を待つ = 端末が消化できた速度)"))
line("フレーム数        : \(frameCounter)")
line("経過              : \(String(format: "%.3f", elapsed)) 秒")
line("実効 fps          : \(String(format: "%.2f", fps))")
line("スループット      : \(String(format: "%.1f", megabytesPerFrame * fps)) MiB/s")
line("")
line("1 フレームあたりの内訳 (ms)")
line("  shm 作成        : \(shmCreateSamples.summaryMilliseconds())   ← shm_open + ftruncate + mmap")
line("  書き込み        : \(fillSamples.summaryMilliseconds())   ← CPU グラデーション生成")
line("  unmap + close   : \(unmapSamples.summaryMilliseconds())")
line("  write(2)        : \(writeSamples.summaryMilliseconds())")
if ackSamples.count > 0 {
    line("  端末応答待ち    : \(ackSamples.summaryMilliseconds())")
}
line("")

let selfCost = shmCreateSamples.mean + fillSamples.mean + unmapSamples.mean + writeSamples.mean
line("送信側の合計      : \(String(format: "%.3f", selfCost * 1000)) ms/frame "
    + "(理論上限 \(String(format: "%.1f", selfCost > 0 ? 1 / selfCost : 0)) fps)")

if stoppedByUser { line("※ キー入力で中断した") }
if let ackFailure { line("※ \(ackFailure)") }
if !errorResponses.isEmpty {
    line("※ 端末がエラー応答を返した (\(errorResponses.count) 件): \(errorResponses.prefix(3).joined(separator: " / "))")
}
if fps < 30 && ackFailure == nil && !stoppedByUser {
    line("※ 30fps に届いていない。解像度を落とすか t=t への切り替えを検討する必要がある。")
}
