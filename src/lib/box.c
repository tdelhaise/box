#include "box/box.h"

#include <stdlib.h>
#include <string.h>
#include <errno.h>

#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/types.h>

void box_fatal(const char *msg) {
    perror(msg);
    exit(EXIT_FAILURE);
}

static int set_reuseaddr(int fd) {
    int yes = 1;
    return setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
}

int box_udp_server(uint16_t port) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return -1;

    (void)set_reuseaddr(fd);

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port        = htons(port);

    if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        int e = errno;
        close(fd);
        errno = e;
        return -1;
    }
    return fd;
}

int box_udp_client(const char *addr, uint16_t port, struct sockaddr_in *out) {
    if (!addr || !out) {
        errno = EINVAL;
        return -1;
    }

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return -1;

    memset(out, 0, sizeof(*out));
    out->sin_family = AF_INET;
    out->sin_port   = htons(port);
    if (inet_pton(AF_INET, addr, &out->sin_addr) != 1) {
        int e = errno ? errno : EINVAL;
        close(fd);
        errno = e;
        return -1;
    }
    return fd;
}

ssize_t box_udp_recv(int fd, void *buf, size_t len, struct sockaddr *src, socklen_t *srclen) {
    for (;;) {
        ssize_t r = recvfrom(fd, buf, len, 0, src, srclen);
        if (r >= 0) return r;
        if (errno == EINTR) continue;
        return -1;
    }
}

ssize_t box_udp_send(int fd, const void *buf, size_t len, const struct sockaddr *dst, socklen_t dstlen) {
    for (;;) {
        ssize_t r = sendto(fd, buf, len, 0, dst, dstlen);
        if (r >= 0) return r;
        if (errno == EINTR) continue;
        return -1;
    }
}

