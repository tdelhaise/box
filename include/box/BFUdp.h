#ifndef BF_UDP_H
#define BF_UDP_H

#include <sys/types.h>
#include <sys/socket.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

ssize_t BFUdpRecieve(int fileDescriptor, void *buffer, size_t length, struct sockaddr *source, socklen_t *sourceLength);
ssize_t BFUdpSend(int fileDescriptor, const void *buffer, size_t length, const struct sockaddr *destination, socklen_t destinationLength);

#ifdef __cplusplus
}
#endif

#endif // BF_UDP_H
