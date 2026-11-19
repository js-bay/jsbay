/* Host regression for preserving every mapped address when normalizing legacy VDSO metadata. */
#include "../../scripts/android-unit-tests/android_phdr_compat.c"
#include <assert.h>

struct expected_view { struct dl_phdr_info *original; int called; int normalized; };
static int check_view(struct dl_phdr_info *view, size_t size, void *opaque) {
    struct expected_view *expected = opaque;
    assert(size == sizeof(*view));
    assert(view->dlpi_phnum == expected->original->dlpi_phnum);
    for (ElfW(Half) i = 0; i < view->dlpi_phnum; ++i) {
        const ElfW(Phdr) *before = &expected->original->dlpi_phdr[i];
        const ElfW(Phdr) *after = &view->dlpi_phdr[i];
        assert(after->p_vaddr <= UINTPTR_MAX - view->dlpi_addr);
        assert(view->dlpi_addr + after->p_vaddr == expected->original->dlpi_addr + before->p_vaddr);
        assert(after->p_type == before->p_type && after->p_memsz == before->p_memsz);
    }
    assert((view != expected->original) == expected->normalized);
    expected->called += 1;
    return 17;
}
int main(void) {
    ElfW(Addr) origin = (ElfW(Addr))0 - 0x900000;
    ElfW(Phdr) headers[3] = {
        { .p_type = PT_LOAD, .p_vaddr = origin, .p_memsz = 0x1000 },
        { .p_type = PT_NOTE, .p_vaddr = origin + 0x324, .p_memsz = 0x34 },
        { .p_type = PT_GNU_EH_FRAME, .p_vaddr = origin + 0x358, .p_memsz = 0x3c }
    };
    struct dl_phdr_info original = { .dlpi_addr = 0x10000000 - origin, .dlpi_name = "[vdso]", .dlpi_phdr = headers, .dlpi_phnum = 3 };
    struct expected_view expected = { &original, 0, 1 };
    struct callback_context context = { check_view, &expected };
    assert(normalized_callback(&original, sizeof(original), &context) == 17);
    assert(expected.called == 1 && headers[0].p_vaddr == origin);
    for (int i = 0; i < 3; ++i) headers[i].p_vaddr -= origin;
    original.dlpi_addr = 0x10000000;
    expected.normalized = 0;
    assert(normalized_callback(&original, sizeof(original), &context) == 17);
    assert(expected.called == 2);
    return 0;
}
