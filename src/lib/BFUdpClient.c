#include "BFUdpClient.h"

#include <arpa/inet.h>
#include <errno.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int BFUdpClient(const char *address, uint16_t port, struct sockaddr_in *outAddress) {
    if (!address || !outAddress) {
        errno = EINVAL;
        return -1;
    }
    int fileDescriptor = socket(AF_INET, SOCK_DGRAM, 0);
    if (fileDescriptor < 0)
        return -1;

    memset(outAddress, 0, sizeof(*outAddress));
    outAddress->sin_family = AF_INET;
    outAddress->sin_port   = htons(port);
    if (inet_pton(AF_INET, address, &outAddress->sin_addr) != 1) {
        int errorCode = errno ? errno : EINVAL;
        close(fileDescriptor);
        errno = errorCode;
        return -1;
    }
    return fileDescriptor;
}
