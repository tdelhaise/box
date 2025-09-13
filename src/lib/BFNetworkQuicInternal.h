#pragma once
// Internal QUIC adapter interface for BFNetwork (CamelCase API).

#include <netinet/in.h>
#include <stddef.h>
#include <sys/socket.h>

typedef struct BFNetworkSecurity BFNetworkSecurity;

void *BFNetworkQuicConnect(int udpFileDescriptor, const struct sockaddr *server, socklen_t serverLength, const BFNetworkSecurity *security);
void *BFNetworkQuicAccept(int udpFileDescriptor, const struct sockaddr_storage *peer, socklen_t peerLength, const BFNetworkSecurity *security);
int   BFNetworkQuicSend(void *handle, const void *buffer, int length);
int   BFNetworkQuicRecv(void *handle, void *buffer, int length);
void  BFNetworkQuicClose(void *handle);
