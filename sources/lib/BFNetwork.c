#include "BFNetwork.h"
#ifdef BOX_USE_QUIC
#include "BFNetworkQuicInternal.h"
#endif
#include "BFNetworkNoiseInternal.h"

#include "BFCommon.h"
#include "BFMemory.h"

#include <string.h>

struct BFNetworkConnection {
    int                udp_fd;
    BFNetworkTransport transport;
    void               *handle; // backend handle (opaque)
};

BFNetworkConnection *BFNetworkConnectDatagram(BFNetworkTransport transport, int udpSocket, const struct sockaddr *server, socklen_t serverLength, const BFNetworkSecurity *security) {
    if (transport == BFNetworkTransportQUIC) {
#ifdef BOX_USE_QUIC
        BFNetworkConnection *networkConnection = (BFNetworkConnection *)BFMemoryAllocate(sizeof(BFNetworkConnection));
		if (!networkConnection) {
			return NULL;
		}
        memset(networkConnection, 0, sizeof(BFNetworkConnection));
        networkConnection->udp_fd    = udpSocket;
        networkConnection->transport = transport;
        networkConnection->handle      = BFNetworkQuicConnect(udpSocket, server, serverLength, security);
        if (!networkConnection->handle) {
            BFMemoryRelease(networkConnection);
            return NULL;
        }
        return networkConnection;
#else
        BFWarn("BFNetwork: QUIC selected but BOX_USE_QUIC=OFF");
        return NULL;
#endif
    }
    if (transport == BFNetworkTransportNOISE) {
        BFNetworkConnection *networkConnection = (BFNetworkConnection *)BFMemoryAllocate(sizeof(BFNetworkConnection));
		if (!networkConnection) {
			return NULL;
		}
        memset(networkConnection, 0, sizeof(BFNetworkConnection));
        networkConnection->udp_fd    = udpSocket;
        networkConnection->transport = transport;
        networkConnection->handle      = BFNetworkNoiseConnect(udpSocket, server, serverLength, security);
        if (!networkConnection->handle) {
            BFMemoryRelease(networkConnection);
            return NULL;
        }
        return networkConnection;
    }
    BFWarn("BFNetwork: transport not implemented (code=%d)", (int)transport);
    return NULL;
}

BFNetworkConnection *BFNetworkAcceptDatagram(BFNetworkTransport transport, int udpSocket, const struct sockaddr_storage *peer, socklen_t peerLength, const BFNetworkSecurity *security) {
    if (transport == BFNetworkTransportQUIC) {
#ifdef BOX_USE_QUIC
        BFNetworkConnection *networkConnection = (BFNetworkConnection *)BFMemoryAllocate(sizeof(BFNetworkConnection));
		if (!networkConnection) {
			return NULL;
		}
        memset(networkConnection, 0, sizeof(BFNetworkConnection));
        networkConnection->udp_fd    = udpSocket;
        networkConnection->transport = transport;
        networkConnection->handle      = BFNetworkQuicAccept(udpSocket, peer, peerLength, security);
        if (!networkConnection->handle) {
            BFMemoryRelease(networkConnection);
            return NULL;
        }
        return c;
#else
        BFWarn("BFNetwork: QUIC selected but BOX_USE_QUIC=OFF");
        return NULL;
#endif
    }
    if (transport == BFNetworkTransportNOISE) {
        BFNetworkConnection *networkConnection = (BFNetworkConnection *)BFMemoryAllocate(sizeof(BFNetworkConnection));
		if (!networkConnection) {
			return NULL;
		}
        memset(networkConnection, 0, sizeof(BFNetworkConnection));
        networkConnection->udp_fd    = udpSocket;
        networkConnection->transport = transport;
        networkConnection->handle      = BFNetworkNoiseAccept(udpSocket, peer, peerLength, security);
        if (!networkConnection->handle) {
            BFMemoryRelease(networkConnection);
            return NULL;
        }
        return networkConnection;
    }
    BFWarn("BFNetwork: transport not implemented (code=%d)", (int)transport);
    return NULL;
}

int BFNetworkSend(BFNetworkConnection *networkConnection, const void *buffer, int length) {
    if (!networkConnection)
        return BF_ERR;
#ifdef BOX_USE_QUIC
    if (networkConnection->transport == BFNetworkTransportQUIC)
        return BFNetworkQuicSend(networkConnection->handle, buffer, length);
#endif
    if (networkConnection->transport == BFNetworkTransportNOISE)
        return BFNetworkNoiseSend(networkConnection->handle, buffer, length);
    return BF_ERR;
}

int BFNetworkReceive(BFNetworkConnection *networkConnection, void *buffer, int length) {
	if (!networkConnection) {
		return BF_ERR;
	}
#ifdef BOX_USE_QUIC
	if (networkConnection->transport == BFNetworkTransportQUIC) {
		return BFNetworkQuicRecv(networkConnection->handle, buffer, length);
	}
#endif
	if (networkConnection->transport == BFNetworkTransportNOISE) {
		return BFNetworkNoiseReceive(networkConnection->handle, buffer, length);
	}
    return BF_ERR;
}

void BFNetworkClose(BFNetworkConnection *networkConnection) {
	if (!networkConnection) {
		return;
	}
#ifdef BOX_USE_QUIC
	if (networkConnection->handle) {
		BFNetworkQuicClose(networkConnection->handle);
	}
#endif
    // For NOISE we reuse the same opaque pointer field
    // (close is a no-op if not a NOISE handle)
    // Try closing via NOISE adapter as well.
    BFNetworkNoiseClose(networkConnection->handle);
    BFMemoryRelease(networkConnection);
}

#ifdef BF_NOISE_TEST_HOOKS
extern int BFNetworkNoiseDebugResendLastFrame(void *handle);
int        BFNetworkDebugResendLastFrame(BFNetworkConnection *networkConnection) {
	if (!networkConnection) {
		return BF_ERR;
	}
	if (networkConnection->transport == BFNetworkTransportNOISE) {
		return BFNetworkNoiseDebugResendLastFrame(networkConnection->handle);
	}
    return BF_ERR;
}
#endif
