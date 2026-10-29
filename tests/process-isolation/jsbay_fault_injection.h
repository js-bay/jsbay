/* JSBAY_FAULT_INJECTION — TEST-ONLY header.
 *
 * Declares jsbay_test_trigger_native_fault, which exists in libjsbay ONLY when the
 * library was built with -Dfault-injection=true. Product / ReleaseFast publish builds
 * (build-android.sh, Apple package, library-only defaults) must leave that option OFF;
 * nm on those archives must NOT show this symbol.
 *
 * Not part of the public product ABI in include/jsbay.h. Do not ship this header in
 * SDK packages.
 */
#ifndef JSBAY_FAULT_INJECTION_H
#define JSBAY_FAULT_INJECTION_H

#ifdef __cplusplus
extern "C" {
#endif

/* kind:
 *   0 — abort() / process abort (SIGABRT-class)
 *   1 — intentional low-address store (SIGSEGV-class)
 *   2 — Zig panic (usually abort)
 * Any other value is treated as 0.
 * Does not return when the symbol is present and linked.
 */
void jsbay_test_trigger_native_fault(int kind);

#ifdef __cplusplus
}
#endif

#endif /* JSBAY_FAULT_INJECTION_H */
