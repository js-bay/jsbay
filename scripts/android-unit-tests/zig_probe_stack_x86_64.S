/* x86_64 __zig_probe_stack, from Zig 0.17 compiler_rt/stack_probe.zig.
   Linked only into Android Escargot unit_tests when Zig compiler-rt is omitted
   so LLVM compiler-rt emutls can be used instead. */
    .text
    .globl __zig_probe_stack
    .type  __zig_probe_stack, @function
__zig_probe_stack:
        push   %rcx
        mov    %rax, %rcx
        cmp    $0x1000, %rcx
        jb     2f
1:
        sub    $0x1000, %rsp
        orl    $0, 16(%rsp)
        sub    $0x1000, %rcx
        cmp    $0x1000, %rcx
        ja     1b
2:
        sub    %rcx, %rsp
        orl    $0, 16(%rsp)
        add    %rax, %rsp
        pop    %rcx
        ret
    .size __zig_probe_stack, .-__zig_probe_stack
