#include "BFSocket.h"

#include <netinet/in.h>
#include <sys/socket.h>

int BFSocketSetReuseAddress(int fileDescriptor) {
    int yes = 1;
    return setsockopt(fileDescriptor, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
}
