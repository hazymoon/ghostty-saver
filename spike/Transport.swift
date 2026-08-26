import Foundation

/// フレーム 1 枚を端末へ送る経路。
/// 段階1では kitty graphics protocol の共有メモリ転送（a=T, t=s）だけを実装するが、
/// 将来 a=f（事前ベイクしたアニメーションフレーム）へ差し替えられるよう分離しておく。
protocol FrameTransport {
    /// フレームを送る。write(2) に要した時間を返す。
    func send(frame: ShmFrame) throws -> TimeInterval
    /// 端末に残っている画像・プレースメントを消す。
    func deleteAll() throws
}

enum TransportError: Error, CustomStringConvertible {
    case writeFailed(errno: Int32)

    var description: String {
        switch self {
        case .writeFailed(let e):
            return "write(2) に失敗: errno=\(e) (\(String(cString: strerror(e))))"
        }
    }
}

/// 応答の扱い。
enum QuietLevel: Int {
    /// q=0: OK もエラーも返る。1 フレームごとに応答を読めるので端末の消化速度で律速できる。
    case verbose = 0
    /// q=1: OK は返らずエラーのみ返る。
    case errorsOnly = 1
    /// q=2: 一切返らない。送信側スループットの上限測定用。
    case silent = 2
}

struct KittySharedMemoryTransport: FrameTransport {
    let fd: Int32
    let imageID: UInt32
    let placementID: UInt32
    let quiet: QuietLevel

    /// 毎フレーム変わらない部分（カーソルホーム + APC ヘッダ）。
    private let prefix: [UInt8]
    private let suffix: [UInt8] = Array("\u{1b}\\".utf8)

    init(fd: Int32, width: Int, height: Int, imageID: UInt32 = 1, placementID: UInt32 = 1, quiet: QuietLevel) {
        self.fd = fd
        self.imageID = imageID
        self.placementID = placementID
        self.quiet = quiet

        // p= を省くと Ghostty は毎回「内部プレースメント ID」を採番して placement を
        // 積み増す（graphics_storage.zig の addPlacement）。同じ p を指定すると
        // (image id, placement id) が一致して既存 placement を上書きするので、
        // フレームを送り続けても placement が 1 個で済む。
        // C=1 はプレースメント後にカーソルを動かさない指示。
        let keys = "a=T,f=32,s=\(width),v=\(height),t=s,i=\(imageID),p=\(placementID),q=\(quiet.rawValue),C=1"
        self.prefix = Array("\u{1b}[H\u{1b}_G\(keys);".utf8)
    }

    func send(frame: ShmFrame) throws -> TimeInterval {
        // ペイロードは画像データではなく shm オブジェクト名を base64 したもの。
        let payload = Array(Data(frame.name.utf8).base64EncodedString().utf8)
        var bytes = prefix
        bytes.append(contentsOf: payload)
        bytes.append(contentsOf: suffix)

        let start = monotonicNow()
        try bytes.withUnsafeBufferPointer { try writeAll(fd, $0.baseAddress!, $0.count) }
        return monotonicNow() - start
    }

    func deleteAll() throws {
        let bytes = Array("\u{1b}_Ga=d,d=A\u{1b}\\".utf8)
        try bytes.withUnsafeBufferPointer { try writeAll(fd, $0.baseAddress!, $0.count) }
    }
}

/// 部分書き込みと EINTR を吸収して全バイト書き切る。
func writeAll(_ fd: Int32, _ bytes: UnsafePointer<UInt8>, _ count: Int) throws {
    var offset = 0
    while offset < count {
        let n = write(fd, bytes + offset, count - offset)
        if n < 0 {
            if errno == EINTR { continue }
            throw TransportError.writeFailed(errno: errno)
        }
        offset += n
    }
}

/// 単調時計（秒）。
@inline(__always)
func monotonicNow() -> TimeInterval {
    TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
}
