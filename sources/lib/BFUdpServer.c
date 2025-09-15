#include "BFUdpServer.h"
#include "BFSocket.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int BFUdpServer(uint16_t port) {
    int fileDescriptor = socket(AF_INET, SOCK_DGRAM, 0);
    if (fileDescriptor < 0)
        return -1;

    (void)BFSocketSetReuseAddress(fileDescriptor);

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family      = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    address.sin_port        = htons(port);

    if (bind(fileDescriptor, (struct sockaddr *)&address, sizeof(address)) < 0) {
        int errorCode = errno;
        close(fileDescriptor);
        errno = errorCode;
        return -1;
    }
    return fileDescriptor;
}
