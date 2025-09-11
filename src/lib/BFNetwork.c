#include "box/BFNetwork.h"
#ifdef BOX_USE_QUIC
#include "BFNetworkQuicInternal.h"
#endif

#include "box/BFCommon.h"
#include "box/BFDtls.h"
#include "box/BFMemory.h"

#include <string.h>

struct BFNetworkConnection {
    int           udp_fd;
    BFNetworkTransport transport;
    BFDtls       *dtls; // M1: DTLS backend only
    void         *quic; // M2: QUIC backend handle (opaque)
};

static void fill_dtls_config(const BFNetworkSecurity *sec, BFDtlsConfig *out) {
    if (!out)
        return;
    memset(out, 0, sizeof(*out));
    if (!sec)
        return;
    out->certificateFile     = sec->certificateFile;
    out->keyFile             = sec->keyFile;
    out->preShareKeyIdentity = sec->preShareKeyIdentity;
    out->preShareKey         = sec->preShareKey;
    out->preShareKeyLength   = sec->preShareKeyLength;
    out->cipherList          = sec->cipherList;
    if (sec->expectedHost)
        setenv("BOX_EXPECTED_HOST", sec->expectedHost, 1);
    if (sec->caFile)
        setenv("BOX_CA_FILE", sec->caFile, 1);
    if (sec->caPath)
        setenv("BOX_CA_PATH", sec->caPath, 1);
}

BFNetworkConnection *BFNetworkConnectDatagram(BFNetworkTransport transport, int udpSocket,
                                              const struct sockaddr *server, socklen_t serverLength,
                                              const BFNetworkSecurity *security) {
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
    if (transport != BFNetworkTransportDTLS) {
        BFWarn("BFNetwork: transport not implemented (code=%d)", (int)transport);
        return NULL;
    }
    BFNetworkConnection *c = (BFNetworkConnection *)BFMemoryAllocate(sizeof(*c));
    if (!c)
        return NULL;
    memset(c, 0, sizeof(*c));
    c->udp_fd   = udpSocket;
    c->transport = transport;

    BFDtlsConfig cfg;
    fill_dtls_config(security, &cfg);
    BFDtls *dtls = NULL;
    if (security && (security->certificateFile || security->keyFile ||
                     (security->preShareKeyIdentity && security->preShareKey &&
                      security->preShareKeyLength))) {
        dtls = BFDtlsClientNewEx(udpSocket, &cfg);
    } else {
        dtls = BFDtlsClientNew(udpSocket);
    }
    if (!dtls) {
        BFMemoryRelease(c);
        return NULL;
    }
    if (BFDtlsHandshakeClient(dtls, server, serverLength) != BF_OK) {
        BFDtlsFree(dtls);
        BFMemoryRelease(c);
        return NULL;
    }
    c->dtls = dtls;
    return c;
}

BFNetworkConnection *BFNetworkAcceptDatagram(BFNetworkTransport transport, int udpSocket,
                                             const struct sockaddr_storage *peer,
                                             socklen_t peerLength, const BFNetworkSecurity *security) {
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
    if (transport != BFNetworkTransportDTLS) {
        BFWarn("BFNetwork: transport not implemented (code=%d)", (int)transport);
        return NULL;
    }
    BFNetworkConnection *c = (BFNetworkConnection *)BFMemoryAllocate(sizeof(*c));
    if (!c)
        return NULL;
    memset(c, 0, sizeof(*c));
    c->udp_fd   = udpSocket;
    c->transport = transport;

    BFDtlsConfig cfg;
    fill_dtls_config(security, &cfg);
    BFDtls *dtls = NULL;
    if (security && (security->certificateFile || security->keyFile ||
                     (security->preShareKeyIdentity && security->preShareKey &&
                      security->preShareKeyLength))) {
        dtls = BFDtlsServerNewEx(udpSocket, &cfg);
    } else {
        dtls = BFDtlsServerNew(udpSocket);
    }
    if (!dtls) {
        BFMemoryRelease(c);
        return NULL;
    }
    if (BFDtlsHandshakeServer(dtls, (struct sockaddr_storage *)peer, peerLength) != BF_OK) {
        BFDtlsFree(dtls);
        BFMemoryRelease(c);
        return NULL;
    }
    c->dtls = dtls;
    return c;
}

int BFNetworkSend(BFNetworkConnection *c, const void *buffer, int length) {
    if (!c)
        return BF_ERR;
    if (c->transport == BFNetworkTransportDTLS)
        return BFDtlsSend(c->dtls, buffer, length);
#ifdef BOX_USE_QUIC
    if (c->transport == BFNetworkTransportQUIC)
        return BFNetworkQuicSend(c->quic, buffer, length);
#endif
    return BF_ERR;
}

int BFNetworkRecv(BFNetworkConnection *c, void *buffer, int length) {
    if (!c)
        return BF_ERR;
    if (c->transport == BFNetworkTransportDTLS)
        return BFDtlsRecv(c->dtls, buffer, length);
#ifdef BOX_USE_QUIC
    if (c->transport == BFNetworkTransportQUIC)
        return BFNetworkQuicRecv(c->quic, buffer, length);
#endif
    return BF_ERR;
}

void BFNetworkClose(BFNetworkConnection *c) {
    if (!c)
        return;
    if (c->dtls)
        BFDtlsFree(c->dtls);
#ifdef BOX_USE_QUIC
    if (c->quic)
        BFNetworkQuicClose(c->quic);
#endif
    BFMemoryRelease(c);
}
