#include "socket.h"
#include <limits.h>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>

static int jsbay_socket_startup(void) {
    WSADATA data;
    return WSAStartup(MAKEWORD(2, 2), &data) == 0 ? 0 : -1;
}

static void jsbay_socket_cleanup(void) { WSACleanup(); }
static SOCKET jsbay_socket_native(jsbay_socket_handle handle) { return (SOCKET)(uintptr_t)handle; }
static jsbay_socket_handle jsbay_socket_handle_from(SOCKET socket) { return (jsbay_socket_handle)(uintptr_t)socket; }

static int jsbay_socket_status(int error) {
    if (error == WSAEWOULDBLOCK) return JSBAY_SOCKET_WOULD_BLOCK;
    if (error == WSAEINTR) return JSBAY_SOCKET_INTERRUPTED;
    if (error == WSAECONNABORTED || error == WSAECONNRESET || error == WSAENETDOWN || error == WSAENETRESET || error == WSAESHUTDOWN || error == WSAEMFILE || error == WSAENOBUFS) return JSBAY_SOCKET_TRANSIENT;
    return JSBAY_SOCKET_ERROR;
}

int jsbay_socket_listen(uint16_t requested_port, jsbay_socket_handle *handle, uint16_t *bound_port) {
    if (jsbay_socket_startup() != 0) return -1;
    SOCKET socket_handle = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (socket_handle == INVALID_SOCKET) { jsbay_socket_cleanup(); return -1; }
    int exclusive = 1;
    if (setsockopt(socket_handle, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, (const char *)&exclusive, sizeof(exclusive)) != 0) goto fail;
    struct sockaddr_in address;
    ZeroMemory(&address, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(requested_port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(socket_handle, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(socket_handle, 128) != 0) goto fail;
    int length = sizeof(address);
    if (getsockname(socket_handle, (struct sockaddr *)&address, &length) != 0) goto fail;
    *bound_port = ntohs(address.sin_port);
    *handle = jsbay_socket_handle_from(socket_handle);
    return 0;
fail:
    closesocket(socket_handle);
    jsbay_socket_cleanup();
    return -1;
}

int jsbay_socket_connect(uint16_t port, jsbay_socket_handle *handle) {
    if (jsbay_socket_startup() != 0) return -1;
    SOCKET socket_handle = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (socket_handle == INVALID_SOCKET) { jsbay_socket_cleanup(); return -1; }
    struct sockaddr_in address;
    ZeroMemory(&address, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(socket_handle, (struct sockaddr *)&address, sizeof(address)) != 0) {
        closesocket(socket_handle); jsbay_socket_cleanup(); return -1;
    }
    *handle = jsbay_socket_handle_from(socket_handle);
    return 0;
}

int jsbay_socket_accept(jsbay_socket_handle listener, jsbay_socket_handle *handle) {
    SOCKET accepted = accept(jsbay_socket_native(listener), NULL, NULL);
    if (accepted == INVALID_SOCKET) return jsbay_socket_status(WSAGetLastError());
    if (jsbay_socket_startup() != 0) { closesocket(accepted); return JSBAY_SOCKET_ERROR; }
    *handle = jsbay_socket_handle_from(accepted);
    return JSBAY_SOCKET_OK;
}

int jsbay_socket_nonblocking(jsbay_socket_handle handle, int enabled) {
    u_long mode = enabled ? 1 : 0;
    return ioctlsocket(jsbay_socket_native(handle), FIONBIO, &mode) == 0 ? 0 : -1;
}

intptr_t jsbay_socket_read(jsbay_socket_handle handle, void *buffer, size_t length, int *status) {
    int amount = length > INT_MAX ? INT_MAX : (int)length;
    int count = recv(jsbay_socket_native(handle), (char *)buffer, amount, 0);
    if (count == SOCKET_ERROR) { *status = jsbay_socket_status(WSAGetLastError()); return -1; }
    *status = JSBAY_SOCKET_OK;
    return count;
}

intptr_t jsbay_socket_write(jsbay_socket_handle handle, const void *buffer, size_t length, int *status) {
    int amount = length > INT_MAX ? INT_MAX : (int)length;
    int count = send(jsbay_socket_native(handle), (const char *)buffer, amount, 0);
    if (count == SOCKET_ERROR) { *status = jsbay_socket_status(WSAGetLastError()); return -1; }
    *status = JSBAY_SOCKET_OK;
    return count;
}

int jsbay_socket_poll(jsbay_socket_handle handle, int events, int timeout_ms, int *ready) {
    WSAPOLLFD descriptor;
    descriptor.fd = jsbay_socket_native(handle);
    descriptor.events = (SHORT)(((events & JSBAY_SOCKET_READ) ? POLLRDNORM : 0) | ((events & JSBAY_SOCKET_WRITE) ? POLLWRNORM : 0));
    descriptor.revents = 0;
    int result = WSAPoll(&descriptor, 1, timeout_ms);
    if (result == SOCKET_ERROR) return WSAGetLastError() == WSAEINTR ? 0 : -1;
    *ready = 0;
    if (descriptor.revents & (POLLRDNORM | POLLIN)) *ready |= JSBAY_SOCKET_READ;
    if (descriptor.revents & (POLLWRNORM | POLLOUT)) *ready |= JSBAY_SOCKET_WRITE;
    if (descriptor.revents & (POLLERR | POLLHUP | POLLNVAL)) *ready |= JSBAY_SOCKET_CLOSED;
    return result;
}

void jsbay_socket_shutdown(jsbay_socket_handle handle) { shutdown(jsbay_socket_native(handle), SD_BOTH); }
void jsbay_socket_close(jsbay_socket_handle handle) { closesocket(jsbay_socket_native(handle)); jsbay_socket_cleanup(); }
int jsbay_socket_receive_buffer(jsbay_socket_handle handle, int bytes) { return setsockopt(jsbay_socket_native(handle), SOL_SOCKET, SO_RCVBUF, (const char *)&bytes, sizeof(bytes)); }

#else
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

static int jsbay_socket_status(int error) {
    if (error == EAGAIN || error == EWOULDBLOCK) return JSBAY_SOCKET_WOULD_BLOCK;
    if (error == EINTR) return JSBAY_SOCKET_INTERRUPTED;
    if (error == ECONNABORTED || error == EMFILE || error == ENFILE) return JSBAY_SOCKET_TRANSIENT;
    return JSBAY_SOCKET_ERROR;
}

int jsbay_socket_listen(uint16_t requested_port, jsbay_socket_handle *handle, uint16_t *bound_port) {
    int socket_handle = socket(AF_INET, SOCK_STREAM, 0);
    if (socket_handle < 0) return -1;
    int reuse = 1;
    if (setsockopt(socket_handle, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse)) != 0) goto fail;
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_port = htons(requested_port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(socket_handle, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(socket_handle, 128) != 0) goto fail;
    socklen_t length = sizeof(address);
    if (getsockname(socket_handle, (struct sockaddr *)&address, &length) != 0) goto fail;
    *bound_port = ntohs(address.sin_port);
    *handle = socket_handle;
    return 0;
fail:
    close(socket_handle);
    return -1;
}

int jsbay_socket_connect(uint16_t port, jsbay_socket_handle *handle) {
    int socket_handle = socket(AF_INET, SOCK_STREAM, 0);
    if (socket_handle < 0) return -1;
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(socket_handle, (struct sockaddr *)&address, sizeof(address)) != 0) { close(socket_handle); return -1; }
    *handle = socket_handle;
    return 0;
}

int jsbay_socket_accept(jsbay_socket_handle listener, jsbay_socket_handle *handle) {
    int accepted = accept((int)listener, NULL, NULL);
    if (accepted < 0) return jsbay_socket_status(errno);
    *handle = accepted;
    return JSBAY_SOCKET_OK;
}
int jsbay_socket_nonblocking(jsbay_socket_handle handle, int enabled) {
    int flags = fcntl((int)handle, F_GETFL, 0);
    if (flags < 0) return -1;
    return fcntl((int)handle, F_SETFL, enabled ? flags | O_NONBLOCK : flags & ~O_NONBLOCK);
}
intptr_t jsbay_socket_read(jsbay_socket_handle handle, void *buffer, size_t length, int *status) {
    ssize_t count = recv((int)handle, buffer, length, 0);
    if (count < 0) { *status = jsbay_socket_status(errno); return -1; }
    *status = JSBAY_SOCKET_OK;
    return count;
}
intptr_t jsbay_socket_write(jsbay_socket_handle handle, const void *buffer, size_t length, int *status) {
    ssize_t count = send((int)handle, buffer, length, MSG_NOSIGNAL);
    if (count < 0) { *status = jsbay_socket_status(errno); return -1; }
    *status = JSBAY_SOCKET_OK;
    return count;
}
int jsbay_socket_poll(jsbay_socket_handle handle, int events, int timeout_ms, int *ready) {
    struct pollfd descriptor = {0};
    descriptor.fd = (int)handle;
    descriptor.events = (short)(((events & JSBAY_SOCKET_READ) ? POLLIN : 0) | ((events & JSBAY_SOCKET_WRITE) ? POLLOUT : 0));
    int result = poll(&descriptor, 1, timeout_ms);
    if (result < 0) return errno == EINTR ? 0 : -1;
    *ready = 0;
    if (descriptor.revents & POLLIN) *ready |= JSBAY_SOCKET_READ;
    if (descriptor.revents & POLLOUT) *ready |= JSBAY_SOCKET_WRITE;
    if (descriptor.revents & (POLLERR | POLLHUP | POLLNVAL)) *ready |= JSBAY_SOCKET_CLOSED;
    return result;
}
void jsbay_socket_shutdown(jsbay_socket_handle handle) { shutdown((int)handle, SHUT_RDWR); }
void jsbay_socket_close(jsbay_socket_handle handle) { close((int)handle); }
int jsbay_socket_receive_buffer(jsbay_socket_handle handle, int bytes) { return setsockopt((int)handle, SOL_SOCKET, SO_RCVBUF, &bytes, sizeof(bytes)); }
#endif
