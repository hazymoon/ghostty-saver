import Foundation
import CShim

// 応答が来ない原因を切り分けるための診断モード。
// KGP そのものが届いていないのか、t=s（共有メモリ）だけが失敗しているのかを分ける。

/// 期限まで届いたバイトを全部集める（APC 単位に切らず生のまま見る）。
private func collectRaw(fd: Int32, timeout: TimeInterval) -> [UInt8] {
    var collected: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 256)
    let deadline = monotonicNow() + timeout

    while true {
        let remainingMs = Int32((deadline - monotonicNow()) * 1000)
        if remainingMs <= 0 { break }
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, remainingMs)
        if ready <= 0 { break }
        let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n <= 0 { break }
        collected.append(contentsOf: chunk[0..<n])
    }
    return collected
}

/// 制御文字を見えるように起こす。
private func readable(_ bytes: [UInt8]) -> String {
    guard !bytes.isEmpty else { return "(応答なし)" }
    var out = ""
    for byte in bytes {
        switch byte {
        case 0x1b: out += "<ESC>"
        case 0x07: out += "<BEL>"
        case 0x0a: out += "<LF>"
        case 0x0d: out += "<CR>"
        case 0x20...0x7e: out.append(Character(UnicodeScalar(byte)))
        default: out += String(format: "<%02x>", byte)
        }
    }
    return out
}

private func report(_ fd: Int32, _ text: String) {
    // raw モード中なので改行は CR+LF にする。
    let line = text + "\r\n"
    _ = line.withCString { write(fd, $0, strlen($0)) }

    // 画面はキー入力後に消えてしまうので、リダイレクトされた標準エラーにも残す。
    // 標準エラーが tty のままなら二重表示になるだけなので出さない。
    if isatty(STDERR_FILENO) != 1 {
        let logLine = text + "\n"
        _ = logLine.withCString { write(STDERR_FILENO, $0, strlen($0)) }
    }
}

/// 診断を実行する。呼び出し側が raw モードにしてあることを前提とする。
func runProbe(fd: Int32, size: TerminalSize) {
    func environmentValue(_ key: String) -> String {
        ProcessInfo.processInfo.environment[key] ?? "(未設定)"
    }

    report(fd, "")
    report(fd, "=== 診断 ===")
    report(fd, "TERM         : \(environmentValue("TERM"))")
    report(fd, "TERM_PROGRAM : \(environmentValue("TERM_PROGRAM"))")
    report(fd, "TMUX         : \(environmentValue("TMUX"))")
    report(fd, "winsize      : \(size.columns) cols x \(size.rows) rows / "
        + "\(size.pixelWidth) x \(size.pixelHeight) px "
        + "(1 セル \(size.columns > 0 ? size.pixelWidth / size.columns : 0)"
        + " x \(size.rows > 0 ? size.pixelHeight / size.rows : 0) px)")
    report(fd, "")

    // 事前に溜まっている入力（前の実行の応答など）を捨てる。
    _ = collectRaw(fd: fd, timeout: 0.05)

    func step(_ label: String, _ sequence: [UInt8], timeout: TimeInterval = 1.0) -> [UInt8] {
        _ = sequence.withUnsafeBufferPointer { try? writeAll(fd, $0.baseAddress!, $0.count) }
        let response = collectRaw(fd: fd, timeout: timeout)
        report(fd, "\(label)")
        report(fd, "  -> \(readable(response))")
        return response
    }

    // 1. kitty graphics protocol に対応しているかの標準的な問い合わせ。
    //    OK が返れば APC が端末まで届き、応答も戻ってきている。
    let queryResponse = step(
        "[1] KGP 対応問い合わせ (a=q, t=d)",
        Array("\u{1b}_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\u{1b}\\".utf8)
    )

    // 2. 画像データを直接埋め込む転送（t=d）。ここが通れば KGP の表示経路は生きている。
    let direct = [UInt8](repeating: 0, count: 4 * 4 * 4).enumerated().map { index, _ -> UInt8 in
        index % 4 == 3 ? 255 : (index % 4 == 0 ? 255 : 0)   // 不透明な赤
    }
    let directPayload = Data(direct).base64EncodedString()
    _ = step(
        "[2] 直接転送 (a=T, t=d, 4x4)",
        Array("\u{1b}_Ga=T,f=32,s=4,v=4,i=32,p=1,q=0,C=1;\(directPayload)\u{1b}\\".utf8)
    )

    // 3. 共有メモリ転送（t=s）。ここだけ落ちるなら shm 名・サイズ・権限の問題。
    let probeWidth = 64
    let probeHeight = 64
    do {
        let frame = try ShmFrame.create(
            name: makeShmName(pid: getpid(), counter: 0xffff),
            payloadBytes: probeWidth * probeHeight * 4
        )
        GradientRenderer(width: probeWidth, height: probeHeight).render(into: frame.base, frame: 0)
        frame.closeMapping()
        let namePayload = Data(frame.name.utf8).base64EncodedString()
        report(fd, "  shm 名: \(frame.name) (\(frame.name.utf8.count) バイト) -> base64: \(namePayload)")
        _ = step(
            "[3] 共有メモリ転送 (a=T, t=s, 64x64)",
            Array("\u{1b}_Ga=T,f=32,s=\(probeWidth),v=\(probeHeight),t=s,i=33,p=1,q=0,C=1;\(namePayload)\u{1b}\\".utf8)
        )
    } catch {
        report(fd, "[3] 共有メモリ転送: shm の作成に失敗 -> \(error)")
    }

    report(fd, "")
    if queryResponse.isEmpty {
        report(fd, "判定: [1] にすら応答がない。APC が端末まで届いていないか、応答が横取りされている。")
        if ProcessInfo.processInfo.environment["TMUX"] != nil {
            report(fd, "      TMUX が設定されている。tmux ペイン内で実行している可能性が高い。")
        }
    } else {
        report(fd, "判定: [1] に応答があるので KGP は届いている。[2] と [3] の差を見る。")
    }
    report(fd, "")
    report(fd, "何かキーを押すと終了する。")
    var discard: UInt8 = 0
    _ = read(fd, &discard, 1)
}
