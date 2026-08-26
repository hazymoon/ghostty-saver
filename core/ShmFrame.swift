import Foundation
import CShim

/// macOS の POSIX shm 名は先頭 '/' を含めて 31 バイトまで（PSHMNAMLEN）。
/// Linux（NAME_MAX 相当）より厳しいので、名前は必ずこの範囲に収める。
public let shmNameMaxBytes = 31

// MARK: - 未回収 shm の追跡

// 端末は shm を読んだ後に自分で shm_unlink する。よって通常は追跡不要だが、
// 端末が読まなかったフレーム（t=s 非対応・エラー・端末が遅れている）の領域は
// 誰も unlink せず再起動まで残る。取りこぼしを有界にするためリングで追う。
//
// シグナルハンドラから触るので Swift の Array ではなく生の C バッファに置き、
// 遅延初期化がハンドラ内で走らないよう prepareShmTracking() で先に確保する。

private let shmSlotCount = 16
private let shmSlotBytes = 32
private var shmSlots: UnsafeMutablePointer<CChar>?
private var shmSlotCursor = 0

/// シグナルハンドラを登録するより前に必ず呼ぶ。
public func prepareShmTracking() {
    guard shmSlots == nil else { return }
    let total = shmSlotCount * shmSlotBytes
    let p = UnsafeMutablePointer<CChar>.allocate(capacity: total)
    p.initialize(repeating: 0, count: total)
    shmSlots = p
}

/// 追跡中の shm を全て unlink する。既に端末が unlink 済みなら ENOENT で無害。
public func unlinkTrackedShm() {
    guard let slots = shmSlots else { return }
    for i in 0..<shmSlotCount {
        let p = slots + i * shmSlotBytes
        if p.pointee != 0 {
            _ = shm_unlink(p)
            p.pointee = 0
        }
    }
}

private func trackShm(_ name: UnsafePointer<CChar>) {
    guard let slots = shmSlots else { return }
    let p = slots + shmSlotCursor * shmSlotBytes
    // shmSlotCount フレーム前の領域が残っていれば端末に読まれなかったものなので回収する。
    if p.pointee != 0 { _ = shm_unlink(p) }
    _ = strlcpy(p, name, shmSlotBytes)
    shmSlotCursor = (shmSlotCursor + 1) % shmSlotCount
}

// MARK: - shm フレーム

public enum ShmFrameError: Error, CustomStringConvertible {
    case nameTooLong(String)
    case openFailed(name: String, errno: Int32)
    case truncateFailed(errno: Int32)
    case mapFailed(errno: Int32)

    public var description: String {
        switch self {
        case .nameTooLong(let n):
            return "shm 名が \(shmNameMaxBytes) バイトを超えた: \(n)"
        case .openFailed(let n, let e):
            return "shm_open(\(n)) に失敗: errno=\(e) (\(String(cString: strerror(e))))"
        case .truncateFailed(let e):
            return "ftruncate に失敗: errno=\(e) (\(String(cString: strerror(e))))"
        case .mapFailed(let e):
            return "mmap に失敗: errno=\(e) (\(String(cString: strerror(e))))"
        }
    }
}

/// 1 フレーム分の共有メモリ領域。
/// 端末が読み終えると端末側が shm_unlink するため、フレームごとに作り直す。
public struct ShmFrame {
    public let name: String
    public let fd: Int32
    public let base: UnsafeMutableRawPointer
    /// mmap した長さ（ページサイズの倍数）
    public let mappedBytes: Int
    /// 画像として意味のある長さ（width * height * 4）
    public let payloadBytes: Int

    /// 名前を指定して新規作成する。ftruncate はページ境界に切り上げる。
    public static func create(name: String, payloadBytes: Int) throws -> ShmFrame {
        guard name.utf8.count <= shmNameMaxBytes else {
            throw ShmFrameError.nameTooLong(name)
        }

        let pageSize = Int(getpagesize())
        let mappedBytes = (payloadBytes + pageSize - 1) / pageSize * pageSize

        let fd: Int32 = name.withCString { cname in
            let fd = gs_shm_create(cname)
            if fd >= 0 { trackShm(cname) }
            return fd
        }
        guard fd >= 0 else {
            throw ShmFrameError.openFailed(name: name, errno: errno)
        }

        guard ftruncate(fd, off_t(mappedBytes)) == 0 else {
            let e = errno
            close(fd)
            name.withCString { _ = shm_unlink($0) }
            throw ShmFrameError.truncateFailed(errno: e)
        }

        let base = mmap(nil, mappedBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard let base, base != MAP_FAILED else {
            let e = errno
            close(fd)
            name.withCString { _ = shm_unlink($0) }
            throw ShmFrameError.mapFailed(errno: e)
        }

        return ShmFrame(
            name: name,
            fd: fd,
            base: base,
            mappedBytes: mappedBytes,
            payloadBytes: payloadBytes
        )
    }

    /// マップと fd を閉じる。shm_unlink はしない（端末が読む前に消さないため）。
    public func closeMapping() {
        munmap(base, mappedBytes)
        close(fd)
    }
}

/// shm 名を生成する。31 バイト制限に収めるため pid とカウンタを base36 で詰める。
/// 例: "/gs1n2p.5f"
public func makeShmName(pid: Int32, counter: UInt64) -> String {
    "/gs" + String(UInt32(bitPattern: pid), radix: 36) + "." + String(counter, radix: 36)
}
