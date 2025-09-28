//
//  ServerNetworkInput.c
//  boxd
//
//  Created by Thierry DELHAISE on 27/09/2025.
//

#include "BFCommon.h"
#include "BFMemory.h"
#include "BFRunloop.h"
#include "BFUdp.h"
#include "ServerEventType.h"
#include "ServerNetworkInput.h"
#include "ServerRuntime.h"

#include <errno.h>
#include <sys/socket.h>
#include <string.h>

void ServerNetworkInputHandler(BFRunloop *runloop, BFRunloopEvent *event, void *context) {
    if (!runloop || !event) {
        return;
    }
    if (event->type == BFRunloopEventStop) {
        return;
    }
    if (event->type != ServerEventNetworkInputStart) {
        return;
    }

    ServerRuntimeContext *runtimeContext = (ServerRuntimeContext *)context;
    if (!runtimeContext || runtimeContext->udpSocketDescriptor < 0) {
        return;
    }

    if (runtimeContext->useNoiseTransport) {
        if (!runtimeContext->noiseConnection) {
            struct sockaddr_storage peekAddress;
            socklen_t               peekLength = sizeof(peekAddress);
            uint8_t                 scratch[1];
            ssize_t                 peeked     = recvfrom(runtimeContext->udpSocketDescriptor,
                                            scratch,
                                            sizeof(scratch),
                                            MSG_PEEK,
                                            (struct sockaddr *)&peekAddress,
                                            &peekLength);
            if (peeked < 0) {
                int savedErrno = errno;
                if (savedErrno != EINTR) {
                    BFWarn("boxd: noise peek failed (%d)", savedErrno);
                }
            } else {
                BFNetworkConnection *connection = BFNetworkAcceptDatagram(BFNetworkTransportNOISE,
                                                                           runtimeContext->udpSocketDescriptor,
                                                                           &peekAddress,
                                                                           peekLength,
                                                                           runtimeContext->hasNoiseSecurity ? &runtimeContext->noiseSecurity : NULL);
                if (!connection) {
                    BFWarn("boxd: noise accept failed");
                    (void)recvfrom(runtimeContext->udpSocketDescriptor,
                                   scratch,
                                   sizeof(scratch),
                                   0,
                                   (struct sockaddr *)&peekAddress,
                                   &peekLength);
                } else {
                    runtimeContext->noiseConnection = connection;
                }
            }
        }

        if (runtimeContext->noiseConnection) {
            uint8_t plaintextBuffer[256];
            int     receivedBytes = BFNetworkReceive(runtimeContext->noiseConnection,
                                                     plaintextBuffer,
                                                     (int)sizeof(plaintextBuffer));
            if (receivedBytes > 0) {
                ServerNoisePlaintext *plaintext = ServerNoisePlaintextCreate(plaintextBuffer, (size_t)receivedBytes);
                if (plaintext) {
                    BFRunloopEvent plaintextEvent = {
                        .type    = ServerEventNoisePlaintext,
                        .payload = plaintext,
                        .destroy = ServerNoisePlaintextDestroy,
                    };
                    if (!runtimeContext->mainRunloop || BFRunloopPost(runtimeContext->mainRunloop, &plaintextEvent) != BF_OK) {
                        ServerNoisePlaintextDestroy(plaintext);
                    }
                }
            } else {
                BFWarn("boxd(noise): receive error");
                BFNetworkClose(runtimeContext->noiseConnection);
                runtimeContext->noiseConnection = NULL;
            }
        }
        goto schedule_event;
    }

    uint8_t                receiveBuffer[BF_MACRO_MAX_DATAGRAM_SIZE];
    struct sockaddr_storage peerAddress;
    socklen_t               peerAddressLength = sizeof(peerAddress);
    memset(&peerAddress, 0, sizeof(peerAddress));

    ssize_t receiveCount = BFUdpReceive(runtimeContext->udpSocketDescriptor,
                                        receiveBuffer,
                                        sizeof(receiveBuffer),
                                        (struct sockaddr *)&peerAddress,
                                        &peerAddressLength);
    if (receiveCount < 0) {
        int savedErrno = errno;
        if (savedErrno != EINTR) {
            BFWarn("boxd: network input receive error (%d)", savedErrno);
        }
    } else if (receiveCount > 0) {
        ServerNetworkDatagram *datagram = ServerNetworkDatagramCreate(receiveBuffer,
                                                                      (size_t)receiveCount,
                                                                      &peerAddress,
                                                                      peerAddressLength);
        if (datagram) {
            BFRunloopEvent deliverEvent = {
                .type    = ServerEventNetworkDatagramInbound,
                .payload = datagram,
                .destroy = ServerNetworkDatagramDestroy,
            };
            if (!runtimeContext->mainRunloop || BFRunloopPost(runtimeContext->mainRunloop, &deliverEvent) != BF_OK) {
                ServerNetworkDatagramDestroy(datagram);
            }
        }
    }

schedule_event:
    if (runtimeContext && runtimeContext->runningFlagPointer && *(runtimeContext->runningFlagPointer)) {
        BFRunloopEvent continueEvent = {
            .type    = ServerEventNetworkInputStart,
            .payload = NULL,
            .destroy = NULL,
        };
        (void)BFRunloopPost(runloop, &continueEvent);
    }
}
