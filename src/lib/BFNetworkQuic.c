#include "BFNetworkQuicInternal.h"
#include "box/BFCommon.h"

#ifndef BOX_USE_QUIC

void *BFNetworkQuicConnect(int udpFileDescriptor, const struct sockaddr *server,
                           socklen_t serverLength, const BFNetworkSecurity *security) {
    (void)udpFileDescriptor;
    (void)server;
    (void)serverLength;
    (void)security;
    BFWarn("QUIC backend not built (BOX_USE_QUIC=OFF)");
    return NULL;
}

void *BFNetworkQuicAccept(int udpFileDescriptor, const struct sockaddr_storage *peer,
                          socklen_t peerLength, const BFNetworkSecurity *security) {
    (void)udpFileDescriptor;
    (void)peer;
    (void)peerLength;
    (void)security;
    BFWarn("QUIC backend not built (BOX_USE_QUIC=OFF)");
    return NULL;
}

int BFNetworkQuicSend(void *handle, const void *buffer, int length) {
    (void)handle;
    (void)buffer;
    (void)length;
    return -1;
}

int BFNetworkQuicRecv(void *handle, void *buffer, int length) {
    (void)handle;
    (void)buffer;
    (void)length;
    return -1;
}

void BFNetworkQuicClose(void *handle) {
    (void)handle;
}

#else
#if defined(BOX_QUIC_IMPL_NGTCP2) && defined(HAVE_NGTCP2)
#include <ngtcp2/ngtcp2.h>
#ifdef HAVE_NGTCP2_CRYPTO_OPENSSL
#include <ngtcp2/ngtcp2_crypto_openssl.h>
#include <openssl/err.h>
#include <openssl/ssl.h>
#endif

typedef struct BFNetworkQuicHandle {
    int                     udpFileDescriptor;
    struct sockaddr_storage peerAddress;
    socklen_t               peerLength;
    ngtcp2_conn            *connection; // ngtcp2 connection
#ifdef HAVE_NGTCP2_CRYPTO_OPENSSL
    SSL     *tls; // OpenSSL TLS object for crypto
    SSL_CTX *tlsContext;
#endif
} BFNetworkQuicHandle;

// NOTE: The following functions provide a scaffold for an ngtcp2-based QUIC
// backend. They currently return failure after initializing minimal state.
// Full handshake, event loop, and DATAGRAM support will be added in follow-ups.

static BFNetworkQuicHandle *BFNetworkQuicHandleNew(int                    udpFileDescriptor,
                                                   const struct sockaddr *server,
                                                   socklen_t              serverLength) {
    BFNetworkQuicHandle *h = (BFNetworkQuicHandle *)BFMemoryAllocate(sizeof(*h));
    if (!h)
        return NULL;
    memset(h, 0, sizeof(*h));
    h->udpFileDescriptor = udpFileDescriptor;
    if (server && serverLength <= sizeof(h->peerAddress)) {
        memcpy(&h->peerAddress, server, serverLength);
        h->peerLength = serverLength;
    }
    return h;
}

static void BFNetworkQuicHandleFree(BFNetworkQuicHandle *h) {
    if (!h)
        return;
#ifdef HAVE_NGTCP2_CRYPTO_OPENSSL
    if (h->tls)
        SSL_free(h->tls);
    if (h->tlsContext)
        SSL_CTX_free(h->tlsContext);
#endif
    if (h->connection)
        ngtcp2_conn_del(h->connection);
    BFMemoryRelease(h);
}

void *BFNetworkQuicConnect(int udpFileDescriptor, const struct sockaddr *server,
                           socklen_t serverLength, const BFNetworkSecurity *security) {
    (void)security;
    BFNetworkQuicHandle *handle = BFNetworkQuicHandleNew(udpFileDescriptor, server, serverLength);
    if (!handle) {
        BFWarn("BFNetwork QUIC(ngtcp2): allocation failed");
        return NULL;
    }
    // TODO: Initialize ngtcp2 client connection (ngtcp2_conn_client_new),
    // bind to udpFileDescriptor, configure TLS via ngtcp2_crypto_openssl,
    // set ALPN to "box/1", and perform handshake.
    BFWarn("BFNetwork QUIC(ngtcp2): connect not implemented yet");
    BFNetworkQuicHandleFree(handle);
    return NULL;
}

void *BFNetworkQuicAccept(int udpFileDescriptor, const struct sockaddr_storage *peer,
                          socklen_t peerLength, const BFNetworkSecurity *security) {
    (void)security;
    BFNetworkQuicHandle *handle =
        BFNetworkQuicHandleNew(udpFileDescriptor, (const struct sockaddr *)peer, peerLength);
    if (!handle) {
        BFWarn("BFNetwork QUIC(ngtcp2): allocation failed");
        return NULL;
    }
    // TODO: Initialize ngtcp2 server connection (ngtcp2_conn_server_new),
    // bind to udpFileDescriptor, configure TLS via ngtcp2_crypto_openssl,
    // set ALPN to "box/1", and perform handshake with the discovered peer.
    BFWarn("BFNetwork QUIC(ngtcp2): accept not implemented yet");
    BFNetworkQuicHandleFree(handle);
    return NULL;
}

int BFNetworkQuicSend(void *handle, const void *buffer, int length) {
    (void)buffer;
    (void)length;
    BFNetworkQuicHandle *h = (BFNetworkQuicHandle *)handle;
    if (!h)
        return -1;
    // TODO: Submit a DATAGRAM via ngtcp2 (ngtcp2_conn_submit_datagram) and drive I/O.
    BFWarn("BFNetwork QUIC(ngtcp2): send not implemented yet");
    return -1;
}

int BFNetworkQuicRecv(void *handle, void *buffer, int length) {
    (void)buffer;
    (void)length;
    BFNetworkQuicHandle *h = (BFNetworkQuicHandle *)handle;
    if (!h)
        return -1;
    // TODO: Receive UDP packet, pass to ngtcp2 (ngtcp2_conn_read_pkt),
    // extract DATAGRAM frames into buffer.
    BFWarn("BFNetwork QUIC(ngtcp2): recv not implemented yet");
    return -1;
}

void BFNetworkQuicClose(void *handle) {
    BFNetworkQuicHandle *h = (BFNetworkQuicHandle *)handle;
    BFNetworkQuicHandleFree(h);
}
#else
// BOX_USE_QUIC=ON but no available implementation was detected
void *BFNetworkQuicConnect(int udpFileDescriptor, const struct sockaddr *server,
                           socklen_t serverLength, const BFNetworkSecurity *security) {
    (void)udpFileDescriptor;
    (void)server;
    (void)serverLength;
    (void)security;
    BFWarn("BFNetwork QUIC: no implementation available at build time");
    return NULL;
}
void *BFNetworkQuicAccept(int udpFileDescriptor, const struct sockaddr_storage *peer,
                          socklen_t peerLength, const BFNetworkSecurity *security) {
    (void)udpFileDescriptor;
    (void)peer;
    (void)peerLength;
    (void)security;
    BFWarn("BFNetwork QUIC: no implementation available at build time");
    return NULL;
}
int BFNetworkQuicSend(void *handle, const void *buffer, int length) {
    (void)handle;
    (void)buffer;
    (void)length;
    return -1;
}
int BFNetworkQuicRecv(void *handle, void *buffer, int length) {
    (void)handle;
    (void)buffer;
    (void)length;
    return -1;
}
void BFNetworkQuicClose(void *handle) {
    (void)handle;
}
#endif
#endif
