// BFNetwork — BoxFoundation Network Abstraction (TAPS-inspired)
// Minimal M1 surface: datagram secure transport (DTLS backend), ready for QUIC later.

#ifndef BF_NETWORK_H
#define BF_NETWORK_H

#include <netinet/in.h>
#include <stddef.h>
#include <sys/socket.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BFNetworkConnection BFNetworkConnection;

typedef enum BFNetworkTransport {
    BFNetworkTransportDTLS = 1,
    BFNetworkTransportQUIC = 2, // reserved; not implemented in M1
} BFNetworkTransport;

// Security configuration (subset; mirrors BFDtls + room for QUIC)
typedef struct BFNetworkSecurity {
    const char *certificateFile; // PEM (optional)
    const char *keyFile;         // PEM (optional)

    const char          *preShareKeyIdentity; // optional (DTLS-PSK)
    const unsigned char *preShareKey;         // optional (binary)
    size_t               preShareKeyLength;

    const char *cipherList;   // OpenSSL cipher list (DTLS)
    const char *expectedHost; // for client verification
    const char *alpn;         // ex: "box/1" (for QUIC/TLS later)
    const char *caFile;       // optional path to CA file (client)
    const char *caPath;       // optional path to CA dir (client)
} BFNetworkSecurity;

// Create a client-side secure connection over a datagram socket (DTLS backend for now).
// The function does not take ownership of udpSocket. Returns NULL on failure.
BFNetworkConnection *BFNetworkConnectDatagram(BFNetworkTransport transport, int udpSocket,
                                              const struct sockaddr *server, socklen_t serverLength,
                                              const BFNetworkSecurity *security);

// Create a server-side secure connection over a datagram socket with a known peer
// (peer discovered by a cleartext datagram). Returns NULL on failure.
BFNetworkConnection *BFNetworkAcceptDatagram(BFNetworkTransport transport, int udpSocket,
                                             const struct sockaddr_storage *peer,
                                             socklen_t peerLength, const BFNetworkSecurity *security);

// I/O operations (blocking). Return number of bytes or BF_ERR (<0) on error.
int BFNetworkSend(BFNetworkConnection *c, const void *buffer, int length);
int BFNetworkRecv(BFNetworkConnection *c, void *buffer, int length);

// Close and free the connection.
void BFNetworkClose(BFNetworkConnection *c);

#ifdef __cplusplus
}
#endif

#endif // BF_NETWORK_H
