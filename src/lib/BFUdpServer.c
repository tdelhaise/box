#include "box/BFUdpServer.h"
#include "box/BFCommon.h"

#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>

int BFUdpServer(uint16_t port) {
    int fileDescriptor = socket(AF_INET, SOCK_DGRAM, 0);
    if (fileDescriptor < 0) return -1;

    (void)setReuseAddress(fileDescriptor);

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
