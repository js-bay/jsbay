/* Android platform compatibility; independent of Java and JNI. */
#define _GNU_SOURCE 1
#include <sys/types.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <unistd.h>
#include <sys/syscall.h>

/* Android Bionic libc uses __assert2 instead of glibc/musl __assert_fail. Provide fallback. */
void __assert_fail(const char *assertion, const char *file, unsigned int line, const char *function) {
    (void)assertion; (void)file; (void)line; (void)function;
    abort();
}

/* Android Bionic libc uses __errno() instead of musl __errno_location() */
extern int* __errno(void);
int* __errno_location(void) {
    return __errno();
}

/* Android < 33 compatibility: bcmp is an alias to memcmp */
int bcmp(const void *s1, const void *s2, size_t n) {
    return memcmp(s1, s2, n);
}

/* copy_file_range syscall wrapper for Android Bionic */
#ifndef __NR_copy_file_range
#if defined(__aarch64__)
#define __NR_copy_file_range 285
#elif defined(__x86_64__)
#define __NR_copy_file_range 326
#elif defined(__arm__)
#define __NR_copy_file_range 391
#elif defined(__i386__)
#define __NR_copy_file_range 377
#endif
#endif
ssize_t copy_file_range(int fd_in, int64_t *off_in, int fd_out, int64_t *off_out, size_t len, unsigned int flags) {
#ifdef __NR_copy_file_range
    return syscall(__NR_copy_file_range, fd_in, off_in, fd_out, off_out, len, flags);
#else
    (void)fd_in; (void)off_in; (void)fd_out; (void)off_out; (void)len; (void)flags;
    return -1;
#endif
}
