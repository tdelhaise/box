#include "box/box.h"

#include <stdlib.h>
#include <string.h>
#include <errno.h>

#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/types.h>

void BFFatal(const char *message) {
    perror(message);
    exit(EXIT_FAILURE);
}

static int set_reuseaddr(int fileDescriptor) {
    int yes = 1;
    return setsockopt(fileDescriptor, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
}

int BFUdpServer(uint16_t port) {
    int fileDescriptor = socket(AF_INET, SOCK_DGRAM, 0);
    if (fileDescriptor < 0) return -1;

    (void)set_reuseaddr(fileDescriptor);

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family      = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    address.sin_port        = htons(port);

    if (bind(fileDescriptor, (struct sockaddr*)&address, sizeof(address)) < 0) {
        int e = errno;
        close(fileDescriptor);
        errno = e;
        return -1;
    }
    return fileDescriptor;
}

int BFUdpClient(const char *address, uint16_t port, struct sockaddr_in *outAddress) {
    if (!address || !outAddress) {
        errno = EINVAL;
        return -1;
    }
    int fileDescriptor = socket(AF_INET, SOCK_DGRAM, 0);
    if (fileDescriptor < 0) return -1;

    memset(outAddress, 0, sizeof(*outAddress));
    outAddress->sin_family = AF_INET;
    outAddress->sin_port   = htons(port);
    if (inet_pton(AF_INET, address, &outAddress->sin_addr) != 1) {
        int e = errno ? errno : EINVAL;
        close(fileDescriptor);
        errno = e;
        return -1;
    }
    return fileDescriptor;
}

ssize_t BFUdpRecv(int fileDescriptor, void *buffet, size_t length, struct sockaddr *source, socklen_t *sourceLength) {
    for (;;) {
        ssize_t received = recvfrom(fileDescriptor, buffet, length, 0, source, sourceLength);
        if (received >= 0) return received;
        if (errno == EINTR) continue;
        return -1;
    }
}

ssize_t BFUdpSend(int fileDescriptor, const void *buffet, size_t length, const struct sockaddr *destination, socklen_t destinationLength) {
    for (;;) {
        ssize_t sent = sendto(fileDescriptor, buffet, length, 0, destination, destinationLength);
        if (sent >= 0) return sent;
        if (errno == EINTR) continue;
        return -1;
    }
}

