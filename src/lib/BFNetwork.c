#include "box/BFNetwork.h"
#ifdef BOX_USE_QUIC
#include "BFNetworkQuicInternal.h"
#endif
#include "BFNetworkNoiseInternal.h"

#include "box/BFCommon.h"
#include "box/BFMemory.h"

#include <string.h>

struct BFNetworkConnection {
    int                udp_fd;
    BFNetworkTransport transport;
    void              *quic; // QUIC backend handle (opaque)
};

BFNetworkConnection *BFNetworkConnectDatagram(BFNetworkTransport transport, int udpSocket, const struct sockaddr *server, socklen_t serverLength, const BFNetworkSecurity *security) {
    if (transport == BFNetworkTransportQUIC) {
#ifdef BOX_USE_QUIC
        BFNetworkConnection *c = (BFNetworkConnection *)BFMemoryAllocate(sizeof(*c));
        if (!c)
            return NULL;
        memset(c, 0, sizeof(*c));
        c->udp_fd    = udpSocket;
        c->transport = transport;
        c->quic      = BFNetworkQuicConnect(udpSocket, server, serverLength, security);
        if (!c->quic) {
            BFMemoryRelease(c);
            return NULL;
        }
        return c;
#else
        BFWarn("BFNetwork: QUIC selected but BOX_USE_QUIC=OFF");
        return NULL;
#endif
    }
    if (transport == BFNetworkTransportNOISE) {
        BFNetworkConnection *c = (BFNetworkConnection *)BFMemoryAllocate(sizeof(*c));
        if (!c)
            return NULL;
        memset(c, 0, sizeof(*c));
        c->udp_fd    = udpSocket;
        c->transport = transport;
        c->quic      = BFNetworkNoiseConnect(udpSocket, server, serverLength, security);
        if (!c->quic) {
            BFMemoryRelease(c);
            return NULL;
        }
        return c;
    }
    BFWarn("BFNetwork: transport not implemented (code=%d)", (int)transport);
    return NULL;
}

BFNetworkConnection *BFNetworkAcceptDatagram(BFNetworkTransport transport, int udpSocket, const struct sockaddr_storage *peer, socklen_t peerLength, const BFNetworkSecurity *security) {
    if (transport == BFNetworkTransportQUIC) {
#ifdef BOX_USE_QUIC
        BFNetworkConnection *c = (BFNetworkConnection *)BFMemoryAllocate(sizeof(*c));
        if (!c)
            return NULL;
        memset(c, 0, sizeof(*c));
        c->udp_fd    = udpSocket;
        c->transport = transport;
        c->quic      = BFNetworkQuicAccept(udpSocket, peer, peerLength, security);
        if (!c->quic) {
            BFMemoryRelease(c);
            return NULL;
        }
        return c;
#else
        BFWarn("BFNetwork: QUIC selected but BOX_USE_QUIC=OFF");
        return NULL;
#endif
    }
    if (transport == BFNetworkTransportNOISE) {
        BFNetworkConnection *c = (BFNetworkConnection *)BFMemoryAllocate(sizeof(*c));
        if (!c)
            return NULL;
        memset(c, 0, sizeof(*c));
        c->udp_fd    = udpSocket;
        c->transport = transport;
        c->quic      = BFNetworkNoiseAccept(udpSocket, peer, peerLength, security);
        if (!c->quic) {
            BFMemoryRelease(c);
            return NULL;
        }
        return c;
    }
    BFWarn("BFNetwork: transport not implemented (code=%d)", (int)transport);
    return NULL;
}

int BFNetworkSend(BFNetworkConnection *c, const void *buffer, int length) {
    if (!c)
        return BF_ERR;
#ifdef BOX_USE_QUIC
    if (c->transport == BFNetworkTransportQUIC)
        return BFNetworkQuicSend(c->quic, buffer, length);
#endif
    if (c->transport == BFNetworkTransportNOISE)
        return BFNetworkNoiseSend(c->quic, buffer, length);
    return BF_ERR;
}

int BFNetworkRecv(BFNetworkConnection *c, void *buffer, int length) {
    if (!c)
        return BF_ERR;
#ifdef BOX_USE_QUIC
    if (c->transport == BFNetworkTransportQUIC)
        return BFNetworkQuicRecv(c->quic, buffer, length);
#endif
    if (c->transport == BFNetworkTransportNOISE)
        return BFNetworkNoiseRecv(c->quic, buffer, length);
    return BF_ERR;
}

void BFNetworkClose(BFNetworkConnection *c) {
    if (!c)
        return;
#ifdef BOX_USE_QUIC
    if (c->quic)
        BFNetworkQuicClose(c->quic);
#endif
    // For NOISE we reuse the same opaque pointer field
    // (close is a no-op if not a NOISE handle)
    // Try closing via NOISE adapter as well.
    BFNetworkNoiseClose(c->quic);
    BFMemoryRelease(c);
}

#ifdef BF_NOISE_TEST_HOOKS
extern int BFNetworkNoiseDebugResendLastFrame(void *handle);
int        BFNetworkDebugResendLastFrame(BFNetworkConnection *c) {
    if (!c)
        return BF_ERR;
    if (c->transport == BFNetworkTransportNOISE)
        return BFNetworkNoiseDebugResendLastFrame(c->quic);
    return BF_ERR;
}
#endif
