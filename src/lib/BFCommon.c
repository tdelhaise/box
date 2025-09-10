#include "box/BFCommon.h"

#include <stdlib.h>
#include <stdio.h>
#include <errno.h>
#include <sys/socket.h>
#include <netinet/in.h>

void BFFatal(const char *message) {
    perror(message);
    exit(EXIT_FAILURE);
}

int setReuseAddress(int fileDescriptor) {
    int yes = 1;
    return setsockopt(fileDescriptor, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
}
