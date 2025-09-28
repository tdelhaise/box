//
//  ServerRuntime.h
//  boxd
//
//  Shared runtime structures for the boxd runloops.
//

#ifndef ServerRuntime_h
#define ServerRuntime_h

#include "BFData.h"
#include "BFNetwork.h"
#include "BFRunloop.h"
#include "BFSharedDictionary.h"

#include <stddef.h>
#include <stdint.h>
#include <sys/socket.h>

typedef struct ServerNetworkDatagram {
    struct sockaddr_storage peerAddress;
    socklen_t               peerAddressLength;
    uint8_t                *datagramBytes;
    size_t                  datagramLength;
} ServerNetworkDatagram;

typedef struct ServerNetworkSendRequest {
    struct sockaddr_storage peerAddress;
    socklen_t               peerAddressLength;
    uint8_t                *payloadBytes;
    size_t                  payloadLength;
} ServerNetworkSendRequest;

typedef struct ServerNoisePlaintext {
    uint8_t *messageBytes;
    size_t   messageLength;
} ServerNoisePlaintext;

typedef struct ServerRuntimeContext {
    int                  udpSocketDescriptor;
    BFSharedDictionary  *sharedStore;
    BFRunloop           *mainRunloop;
    BFRunloop           *networkInputRunloop;
    BFRunloop           *networkOutputRunloop;
    volatile int        *runningFlagPointer;
    int                  handshakeCompleted;
    int                  useNoiseTransport;
    BFNetworkConnection *noiseConnection;
    BFNetworkSecurity    noiseSecurity;
    int                  hasNoiseSecurity;
    BFData               transmitBuffer;
} ServerRuntimeContext;

ServerNetworkDatagram *ServerNetworkDatagramCreate(const uint8_t *datagramBytes,
                                                   size_t         datagramLength,
                                                   const struct sockaddr_storage *peerAddress,
                                                   socklen_t      peerAddressLength);
void ServerNetworkDatagramDestroy(void *payloadPointer);

ServerNetworkSendRequest *ServerNetworkSendRequestCreate(const uint8_t *payloadBytes,
                                                         size_t         payloadLength,
                                                         const struct sockaddr_storage *peerAddress,
                                                         socklen_t      peerAddressLength);
void ServerNetworkSendRequestDestroy(void *payloadPointer);

ServerNoisePlaintext *ServerNoisePlaintextCreate(const uint8_t *messageBytes, size_t messageLength);
void                 ServerNoisePlaintextDestroy(void *payloadPointer);

#endif /* ServerRuntime_h */
