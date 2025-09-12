// Internal Noise adapter interface for BFNetwork (CamelCase API).

#ifndef BF_NETWORK_NOISE_INTERNAL_H
#define BF_NETWORK_NOISE_INTERNAL_H

#include <netinet/in.h>
#include <sys/socket.h>

typedef struct BFNetworkSecurity BFNetworkSecurity;

void *BFNetworkNoiseConnect(int udpFileDescriptor, const struct sockaddr *server,
                            socklen_t serverLength, const BFNetworkSecurity *security);
void *BFNetworkNoiseAccept(int udpFileDescriptor, const struct sockaddr_storage *peer,
                           socklen_t peerLength, const BFNetworkSecurity *security);
int   BFNetworkNoiseSend(void *handle, const void *buffer, int length);
int   BFNetworkNoiseRecv(void *handle, void *buffer, int length);
void  BFNetworkNoiseClose(void *handle);

#endif // BF_NETWORK_NOISE_INTERNAL_H
