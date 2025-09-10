#include "box/BFSocket.h"

#include <sys/socket.h>
#include <netinet/in.h>

int BFSocketSetReuseAddress(int fileDescriptor) {
    int yes = 1;
    return setsockopt(fileDescriptor, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
}
