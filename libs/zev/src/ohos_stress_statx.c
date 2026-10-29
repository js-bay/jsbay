/* OpenHarmony libc exposes the statx syscall ABI but not the libc symbol required by Zig's threaded I/O support. This source is linked only into the standalone zev stress executable. */
#define _GNU_SOURCE 1
#include <linux/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

int statx(int directory, const char *path, int flags, unsigned int mask,
          struct statx *result) {
    return (int)syscall(SYS_statx, directory, path, flags, mask, result);
}
