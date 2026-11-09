#ifndef JSBAY_INSPECTOR_SOCKET_H
#define JSBAY_INSPECTOR_SOCKET_H

#include <stddef.h>
#include <stdint.h>

typedef intptr_t jsbay_socket_handle;

enum {
    JSBAY_SOCKET_OK = 0,
    JSBAY_SOCKET_WOULD_BLOCK = 1,
    JSBAY_SOCKET_INTERRUPTED = 2,
    JSBAY_SOCKET_TRANSIENT = 3,
    JSBAY_SOCKET_ERROR = -1,
    JSBAY_SOCKET_READ = 1,
    JSBAY_SOCKET_WRITE = 2,
    JSBAY_SOCKET_CLOSED = 4
};

int jsbay_socket_listen(uint16_t requested_port, jsbay_socket_handle *handle, uint16_t *bound_port);
int jsbay_socket_connect(uint16_t port, jsbay_socket_handle *handle);
int jsbay_socket_accept(jsbay_socket_handle listener, jsbay_socket_handle *handle);
int jsbay_socket_nonblocking(jsbay_socket_handle handle, int enabled);
intptr_t jsbay_socket_read(jsbay_socket_handle handle, void *buffer, size_t length, int *status);
intptr_t jsbay_socket_write(jsbay_socket_handle handle, const void *buffer, size_t length, int *status);
int jsbay_socket_poll(jsbay_socket_handle handle, int events, int timeout_ms, int *ready);
void jsbay_socket_shutdown(jsbay_socket_handle handle);
void jsbay_socket_close(jsbay_socket_handle handle);
int jsbay_socket_receive_buffer(jsbay_socket_handle handle, int bytes);

#endif
