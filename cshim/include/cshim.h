#ifndef GS_CSHIM_H
#define GS_CSHIM_H

// Swift は C の可変長引数関数を import しないため、ioctl / shm_open は
// ここで固定引数の static inline に包んで渡す。
// TIOCGWINSZ のような _IOR マクロも Swift からは見えないので同様。

#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <termios.h>
#include <unistd.h>

/// 端末のセル数・ピクセルサイズを取得する。成功で 0。
static inline int gs_winsize(int fd, struct winsize *ws) {
    return ioctl(fd, TIOCGWINSZ, ws);
}

/// 新規作成専用の shm_open（O_CREAT|O_EXCL|O_RDWR, mode 0600）。
/// 既存名なら EEXIST で失敗させ、他プロセスの領域を掴まないようにする。
static inline int gs_shm_create(const char *name) {
    return shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
}

#endif
