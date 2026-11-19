/* Test-only normalization of legacy Android x86_64 VDSO metadata. */
#define _GNU_SOURCE 1
#include <dlfcn.h>
#include <errno.h>
#include <link.h>
#include <stdint.h>
#include <string.h>

typedef int (*phdr_callback)(struct dl_phdr_info *, size_t, void *);
struct callback_context { phdr_callback callback; void *data; };

static int normalized_callback(struct dl_phdr_info *info, size_t size, void *opaque) {
    struct callback_context *context = opaque;
    /* Legacy VDSOs use fixed negative virtual addresses and a compensating load bias. Normalize both together so checked address arithmetic preserves every original mapped NOTE and unwind address. */
    if (info->dlpi_name && strcmp(info->dlpi_name, "[vdso]") == 0 && info->dlpi_phnum <= 64) {
        ElfW(Addr) origin = 0;
        for (ElfW(Half) i = 0; i < info->dlpi_phnum; ++i) {
            if (info->dlpi_phdr[i].p_type == PT_LOAD) { origin = info->dlpi_phdr[i].p_vaddr; break; }
        }
        if (origin > UINTPTR_MAX / 2) {
            ElfW(Phdr) headers[64];
            memcpy(headers, info->dlpi_phdr, info->dlpi_phnum * sizeof(headers[0]));
            for (ElfW(Half) i = 0; i < info->dlpi_phnum; ++i) {
                if (headers[i].p_vaddr >= origin) headers[i].p_vaddr -= origin;
            }
            struct dl_phdr_info normalized = {0};
            memcpy(&normalized, info, size < sizeof(normalized) ? size : sizeof(normalized));
            normalized.dlpi_addr += origin;
            normalized.dlpi_phdr = headers;
            return context->callback(&normalized, size, context->data);
        }
    }
    return context->callback(info, size, context->data);
}

int dl_iterate_phdr(phdr_callback callback, void *data) {
    typedef int (*iterate_function)(phdr_callback, void *);
    void *libc = dlopen("libc.so", RTLD_NOW | RTLD_LOCAL);
    if (!libc) { errno = ENOSYS; return -1; }
    iterate_function next = (iterate_function)dlsym(libc, "dl_iterate_phdr");
    if (!next || next == dl_iterate_phdr) { dlclose(libc); errno = ENOSYS; return -1; }
    struct callback_context context = { callback, data };
    int result = next(normalized_callback, &context);
    dlclose(libc);
    return result;
}
