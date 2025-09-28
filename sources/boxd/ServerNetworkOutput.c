//
//  ServerNetworkOutput.c
//  boxd
//
//  Created by Thierry DELHAISE on 27/09/2025.
//

#include "BFCommon.h"
#include "BFRunloop.h"
#include "BFUdp.h"
#include "ServerEventType.h"
#include "ServerNetworkOutput.h"
#include "ServerRuntime.h"

void ServerNetworkOutputHandler(BFRunloop *runloop, BFRunloopEvent *event, void *context) {
    (void)runloop;
    if (!event || event->type == BFRunloopEventStop) {
        return;
    }
    if (event->type != ServerEventNetworkOutputSend) {
        return;
    }

    ServerRuntimeContext    *runtimeContext = (ServerRuntimeContext *)context;
    ServerNetworkSendRequest *sendRequest   = (ServerNetworkSendRequest *)event->payload;
    if (!runtimeContext || runtimeContext->udpSocketDescriptor < 0 || !sendRequest) {
        return;
    }

    if (runtimeContext->useNoiseTransport) {
        if (!runtimeContext->noiseConnection) {
            BFWarn("boxd: noise send skipped (connection not ready)");
            return;
        }
        int sendResult = BFNetworkSend(runtimeContext->noiseConnection,
                                       sendRequest->payloadBytes,
                                       (int)sendRequest->payloadLength);
        if (sendResult <= 0) {
            BFWarn("boxd: noise send error");
        }
        return;
    }

    ssize_t sentCount = BFUdpSend(runtimeContext->udpSocketDescriptor,
                                  sendRequest->payloadBytes,
                                  sendRequest->payloadLength,
                                  (struct sockaddr *)&sendRequest->peerAddress,
                                  sendRequest->peerAddressLength);
    if (sentCount < 0) {
        BFWarn("boxd: network output send error");
    }
}
