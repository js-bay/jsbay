#include "jsbay.h"
#include <pthread.h>
#include <stdio.h>
#include <string.h>

static void *read_command(void *data) {
    const int id = *(const int *)data;
    char command[16];
    if (!fgets(command, sizeof command, stdin) || strcmp(command, "quit\n"))
        return (void *)1;
    if (!jsbay_engine_stop_loop(id)) return (void *)1;
    return NULL;
}

int main(void) {
    const int id = 4071;
    uint16_t port = 0;
    setvbuf(stdout, NULL, _IONBF, 0);
    if (!jsbay_engine_create(id, NULL, NULL)) return 1;
    if (!jsbay_engine_inspector_start(id, 0, &port)) return 2;
    pthread_t reader;
    if (pthread_create(&reader, NULL, read_command, (void *)&id)) return 3;
    printf("READY %u\n", port);
    puts("LOOP_RUNNING");
    const jsbay_status_t status = jsbay_engine_run_loop(id);
    void *reader_result = NULL;
    if (pthread_join(reader, &reader_result) || reader_result || status != JSBAY_OK) return 4;
    jsbay_engine_destroy(id);
    puts("CLEAN_EXIT");
    return 0;
}
