/* Process-isolation harness: intentional Zig/native abort kills only the child.
 *
 * Modes:
 *   (default)                 parent — abort + segfault child, then healthy child
 *   --storm <N>               sequential abort×N then segfault×N then healthy
 *   --storm-parallel <N>      fork N abort children at once, wait all, then healthy
 *   --fault-child <kind>      call jsbay_test_trigger_native_fault (must die)
 *   --healthy-child           create engine, evaluate 2+2, destroy, exit 0
 *
 * Link against a libjsbay built with -Dfault-injection=true.
 * Greppable PASS: / FAIL: lines. Exit 0 only when parent containment passes.
 */
#include "jsbay.h"
#include "jsbay_fault_injection.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define TEXT(value) ((jsbay_utf8_t){(const uint8_t *)(value), sizeof(value) - 1})

static int failures = 0;

static void pass(const char *name) { printf("PASS: %s\n", name); }

static void fail(const char *name, const char *detail) {
    failures++;
    printf("FAIL: %s — %s\n", name, detail);
}

static int run_healthy_engine(void) {
    const int id = 7701;
    jsbay_value_t value = 0;
    jsbay_value_t exception = 0;
    jsbay_status_t st;
    double number = 0.0;

    if (!jsbay_engine_create(id, NULL, NULL)) {
        fprintf(stderr, "healthy: create failed\n");
        return 2;
    }
    st = jsbay_engine_evaluate(id, TEXT("2+2"), TEXT("healthy.js"), NULL, &value, &exception);
    if (st != JSBAY_OK || value == 0 || exception != 0) {
        fprintf(stderr, "healthy: evaluate failed status=%d\n", (int)st);
        if (value) jsbay_value_release(value);
        if (exception) jsbay_value_release(exception);
        jsbay_engine_destroy(id);
        return 3;
    }
    if (jsbay_value_to_number(value, &number) != JSBAY_OK || number != 4.0) {
        fprintf(stderr, "healthy: bad number\n");
        jsbay_value_release(value);
        jsbay_engine_destroy(id);
        return 4;
    }
    jsbay_value_release(value);
    jsbay_engine_destroy(id);
    printf("PASS: healthy-child evaluate=4\n");
    return 0;
}

static int spawn_and_wait(char *const argv[], int *out_status, int *out_signaled, int *out_termsig) {
    pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        return -1;
    }
    if (pid == 0) {
        execv(argv[0], argv);
        _exit(127);
    }
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        perror("waitpid");
        return -1;
    }
    *out_status = status;
    if (WIFSIGNALED(status)) {
        *out_signaled = 1;
        *out_termsig = WTERMSIG(status);
        return 0;
    }
    *out_signaled = 0;
    *out_termsig = 0;
    return 0;
}

static int child_died_from_fault(int status, int signaled) {
    if (signaled) return 1;
    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) return 0;
    /* Some platforms / adb wrappers convert signal death to a non-zero exit. */
    if (WIFEXITED(status) && WEXITSTATUS(status) != 0) return 1;
    return 0;
}

static void run_fault_round(char *self, int kind, const char *label) {
    char kind_buf[8];
    char *fault_argv[] = {self, "--fault-child", kind_buf, NULL};
    int status = 0, signaled = 0, termsig = 0;
    char detail[160];

    snprintf(kind_buf, sizeof(kind_buf), "%d", kind);
    if (spawn_and_wait(fault_argv, &status, &signaled, &termsig) != 0) {
        fail(label, "spawn/wait failed");
        return;
    }
    if (!child_died_from_fault(status, signaled)) {
        fail(label, "child exited 0 instead of faulting");
        return;
    }
    snprintf(detail, sizeof(detail), "child_status=0x%x signaled=%d termsig=%d parent_alive=1", status,
             signaled, termsig);
    pass(detail);
    pass(label);
}

static void run_healthy_round(char *self) {
    char *healthy_argv[] = {self, "--healthy-child", NULL};
    int status = 0, signaled = 0, termsig = 0;
    char detail[128];

    if (spawn_and_wait(healthy_argv, &status, &signaled, &termsig) != 0) {
        fail("parent-continues-after-fault", "healthy spawn failed");
        return;
    }
    if (signaled || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        snprintf(detail, sizeof(detail), "healthy child failed status=0x%x signaled=%d", status, signaled);
        fail("parent-continues-after-fault", detail);
        return;
    }
    pass("parent-continues-after-fault");
}

static int parent_main(char *self) {
    run_fault_round(self, 0, "parent-survives-abort-child");
    run_fault_round(self, 1, "parent-survives-segfault-child");
    run_healthy_round(self);

    if (failures != 0) {
        printf("FAIL: process-isolation harness failures=%d\n", failures);
        return 1;
    }
    printf("PASS: process-isolation harness complete\n");
    return 0;
}

static int storm_sequential(char *self, int n) {
    char label[64];
    int i;

    printf("INFO: storm-sequential n=%d\n", n);
    for (i = 0; i < n; i++) {
        snprintf(label, sizeof(label), "storm-abort-%d", i);
        run_fault_round(self, 0, label);
    }
    snprintf(label, sizeof(label), "storm-abort-all-%d", n);
    if (failures == 0) pass(label); else fail(label, "one or more abort children leaked to parent");

    for (i = 0; i < n; i++) {
        snprintf(label, sizeof(label), "storm-segfault-%d", i);
        run_fault_round(self, 1, label);
    }
    snprintf(label, sizeof(label), "storm-segfault-all-%d", n);
    if (failures == 0) pass(label); else fail(label, "one or more segfault children leaked to parent");

    run_healthy_round(self);

    if (failures != 0) {
        printf("FAIL: storm-sequential failures=%d\n", failures);
        return 1;
    }
    printf("PASS: storm-sequential complete n=%d\n", n);
    return 0;
}

static int storm_parallel(char *self, int n) {
    pid_t *pids;
    char kind_buf[8];
    char *fault_argv[] = {self, "--fault-child", kind_buf, NULL};
    int i, survived = 0, died = 0;
    char detail[160];

    if (n < 1) n = 1;
    if (n > 256) n = 256;
    pids = calloc((size_t)n, sizeof(pid_t));
    if (!pids) {
        fail("storm-parallel", "calloc failed");
        return 1;
    }

    snprintf(kind_buf, sizeof(kind_buf), "%d", 0);
    printf("INFO: storm-parallel abort n=%d\n", n);
    for (i = 0; i < n; i++) {
        pid_t pid = fork();
        if (pid < 0) {
            fail("storm-parallel", "fork failed");
            /* Best-effort wait already-forked children before returning. */
            for (int j = 0; j < i; j++) {
                if (pids[j] > 0) waitpid(pids[j], NULL, 0);
            }
            free(pids);
            return 1;
        }
        if (pid == 0) {
            execv(fault_argv[0], fault_argv);
            _exit(127);
        }
        pids[i] = pid;
    }

    for (i = 0; i < n; i++) {
        int status = 0;
        if (waitpid(pids[i], &status, 0) < 0) {
            fail("storm-parallel", "waitpid failed");
            continue;
        }
        if (WIFSIGNALED(status) || (WIFEXITED(status) && WEXITSTATUS(status) != 0)) {
            died++;
        } else {
            survived++;
            snprintf(detail, sizeof(detail), "child[%d] exited cleanly status=0x%x", i, status);
            fail("storm-parallel-child-survived", detail);
        }
    }
    free(pids);

    snprintf(detail, sizeof(detail), "died=%d clean_survivors=%d parent_alive=1", died, survived);
    if (survived == 0 && died == n) {
        pass(detail);
        pass("storm-parallel-abort");
    } else {
        fail("storm-parallel-abort", detail);
    }

    run_healthy_round(self);

    if (failures != 0) {
        printf("FAIL: storm-parallel failures=%d\n", failures);
        return 1;
    }
    printf("PASS: storm-parallel complete n=%d\n", n);
    return 0;
}

int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "--fault-child") == 0) {
        int kind = 0;
        if (argc >= 3) kind = atoi(argv[2]);
        fprintf(stderr, "fault-child kind=%d triggering native fault\n", kind);
        fflush(stderr);
        jsbay_test_trigger_native_fault(kind);
        fprintf(stderr, "FAULT: jsbay_test_trigger_native_fault returned\n");
        return 42;
    }
    if (argc >= 2 && strcmp(argv[1], "--healthy-child") == 0) {
        return run_healthy_engine();
    }
    if (argc >= 3 && strcmp(argv[1], "--storm") == 0) {
        return storm_sequential(argv[0], atoi(argv[2]));
    }
    if (argc >= 3 && strcmp(argv[1], "--storm-parallel") == 0) {
        return storm_parallel(argv[0], atoi(argv[2]));
    }
    return parent_main(argv[0]);
}
