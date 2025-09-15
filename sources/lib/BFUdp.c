#include "BFUdp.h"

#include <errno.h>

ssize_t BFUdpReceive(int fileDescriptor, void *buffer, size_t length, struct sockaddr *source, socklen_t *sourceLength) {
    for (;;) {
        ssize_t received = recvfrom(fileDescriptor, buffer, length, 0, source, sourceLength);
        if (received >= 0) {
            return received;
        }
        if (errno == EINTR)
            continue;

        return -1;
    }
}

ssize_t BFUdpSend(int fileDescriptor, const void *buffer, size_t length, const struct sockaddr *destination, socklen_t destinationLength) {
    for (;;) {
        ssize_t sent = sendto(fileDescriptor, buffer, length, 0, destination, destinationLength);
        if (sent >= 0) {
            return sent;
        }
        if (errno == EINTR)
            continue;

        return -1;
    }
}
