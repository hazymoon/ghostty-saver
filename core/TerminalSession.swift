import Foundation

// 端末の状態変更と復帰をまとめる。
// 復帰はシグナルハンドラからも呼ばれるため、状態はファイルスコープのグローバルに置く。
// prepare() で先に触っておき、遅延初期化がハンドラ内で走らないようにする。

private var outputDescriptor: Int32 = STDOUT_FILENO
private var originalTermios = termios()
private var termiosSaved = false
private var altScreenEntered = false
private var restored = false

public enum TerminalSession {
    /// 端末への書き込み先。
    public static var outputFD: Int32 { outputDescriptor }

    /// 出力先を決めて開く。tty かどうかを返す。
    /// sinkPath があればそこへ、無ければ標準出力、リダイレクトされていれば /dev/tty。
    @discardableResult
    public static func openOutput(sinkPath: String?) -> Bool {
        if let sinkPath {
            let fd = open(sinkPath, O_WRONLY)
            if fd >= 0 { outputDescriptor = fd }
        } else if isatty(STDOUT_FILENO) == 1 {
            outputDescriptor = STDOUT_FILENO
        } else {
            let fd = open("/dev/tty", O_RDWR)
            outputDescriptor = fd >= 0 ? fd : STDOUT_FILENO
        }
        return isatty(outputDescriptor) == 1
    }

    /// shm 追跡の確保とシグナルハンドラ・atexit の登録。端末を触る前に呼ぶ。
    public static func prepare() {
        prepareShmTracking()
        // グローバルを先に触って初期化を済ませておく。
        _ = outputDescriptor
        _ = termiosSaved
        _ = altScreenEntered
        _ = restored

        let handler: @convention(c) (Int32) -> Void = { signalNumber in
            TerminalSession.restore()
            signal(signalNumber, SIG_DFL)
            raise(signalNumber)
        }
        signal(SIGINT, handler)
        signal(SIGTERM, handler)
        signal(SIGHUP, handler)
        atexit { TerminalSession.restore() }
    }

    /// raw モードにする。1 バイト読めたら返る設定。
    public static func enterRawMode() {
        var raw = termios()
        guard tcgetattr(outputDescriptor, &raw) == 0 else { return }
        originalTermios = raw
        termiosSaved = true
        cfmakeraw(&raw)
        raw.c_cc.16 = 1   // VMIN
        raw.c_cc.17 = 0   // VTIME
        tcsetattr(outputDescriptor, TCSANOW, &raw)
    }

    public static func enterAltScreen() {
        write("\u{1b}[?1049h")
        altScreenEntered = true
    }

    public static func hideCursor() {
        write("\u{1b}[?25l")
    }

    /// 画像削除 → カーソル表示 → 代替画面終了 → termios 復帰 → shm 回収。
    /// 何度呼んでも 1 度しか実行しない。
    public static func restore() {
        if restored { return }
        restored = true

        var sequence = "\u{1b}_Ga=d,d=A\u{1b}\\\u{1b}[?25h"
        if altScreenEntered { sequence += "\u{1b}[?1049l" }
        write(sequence)

        if termiosSaved {
            tcsetattr(outputDescriptor, TCSANOW, &originalTermios)
        }
        unlinkTrackedShm()
    }

    private static func write(_ text: String) {
        _ = text.withCString { Darwin.write(outputDescriptor, $0, strlen($0)) }
    }
}
