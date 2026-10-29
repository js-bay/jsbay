/* OHOS libc does not export statx, although its syscall ABI is present in the SDK headers. Zig's threaded I/O uses the libc entry point. */
#define _GNU_SOURCE 1
#include <linux/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

int statx(int directory, const char *path, int flags, unsigned int mask,
          struct statx *result) {
    return (int)syscall(SYS_statx, directory, path, flags, mask, result);
}
