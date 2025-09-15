#ifndef BF_UDP_CLIENT_H
#define BF_UDP_CLIENT_H

#include <netinet/in.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int BFUdpClient(const char *address, uint16_t port, struct sockaddr_in *outAddress);

#ifdef __cplusplus
}
#endif

#endif // BF_UDP_CLIENT_H
