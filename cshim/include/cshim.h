#ifndef GS_CSHIM_H
#define GS_CSHIM_H

// Swift does not import C variadic functions, so ioctl and shm_open are wrapped
// here as fixed-arity static inlines. Macros such as TIOCGWINSZ are invisible to
// Swift for the same reason.

#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <termios.h>
#include <unistd.h>

/// Fetches the terminal's cell and pixel dimensions. Returns 0 on success.
static inline int gs_winsize(int fd, struct winsize *ws) {
    return ioctl(fd, TIOCGWINSZ, ws);
}

/// shm_open restricted to creation (O_CREAT|O_EXCL|O_RDWR, mode 0600).
/// An existing name fails with EEXIST rather than handing back another
/// process's segment.
static inline int gs_shm_create(const char *name) {
    return shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
}

/// Opens an existing segment read-only. Used to observe whether a name is still
/// present; shm_open is variadic, so Swift cannot call it directly.
static inline int gs_shm_open_readonly(const char *name) {
    return shm_open(name, O_RDONLY, 0);
}

#endif
