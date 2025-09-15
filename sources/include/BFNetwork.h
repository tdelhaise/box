// BFNetwork — BoxFoundation Network Abstraction (TAPS-inspired)
// Minimal surface: datagram secure transport (Noise/QUIC planned). No DTLS.

#ifndef BF_NETWORK_H
#define BF_NETWORK_H

#include <netinet/in.h>
#include <stddef.h>
#include <sys/socket.h>

#ifdef __cplusplus
extern "C" {
#endif

#define BF_MACRO_SIZE_ASSOCIATED_HEADER 4

typedef struct BFNetworkConnection BFNetworkConnection;

typedef enum BFNetworkTransport {
    BFNetworkTransportQUIC  = 1, // reserved; not implemented yet
    BFNetworkTransportNOISE = 2, // libsodium/Noise (groundwork)
} BFNetworkTransport;

// Noise handshake pattern (scaffold)
typedef enum BFNoiseHandshakePattern {
    BFNoiseHandshakePatternUnknown = 0,
    BFNoiseHandshakePatternNK      = 1, // initiator knows responder static
    BFNoiseHandshakePatternIK      = 2, // both sides know each other's static
} BFNoiseHandshakePattern;

// Security configuration (for future Noise/QUIC transports)
typedef struct BFNetworkSecurity {
    const char *certificateFile; // PEM (optional)
    const char *keyFile;         // PEM (optional)

    const char          *preShareKeyIdentity; // optional
    const unsigned char *preShareKey;         // optional (binary)
    size_t               preShareKeyLength;

    const char *cipherList;   // reserved for TLS/QUIC backends
    const char *expectedHost; // for client verification
    const char *alpn;         // ex: "box/1" (for QUIC/TLS later)
    const char *caFile;       // optional path to CA file (client)
    const char *caPath;       // optional path to CA dir (client)

    // Noise scaffold options (all optional). If provided, identities are bound into
    // the session key derivation and transcript hash. This does not yet implement
    // full message patterns; it only derives a transport key that both sides can
    // compute from shared configuration for smoke testing.
    int                     hasNoiseHandshakePattern;
    BFNoiseHandshakePattern noiseHandshakePattern;
    const unsigned char    *noiseClientStaticPublicKey; // 32 bytes (optional)
    size_t                  noiseClientStaticPublicKeyLength;
    const unsigned char    *noiseClientStaticPrivateKey; // 32 bytes (optional)
    size_t                  noiseClientStaticPrivateKeyLength;
    const unsigned char    *noiseServerStaticPublicKey; // 32 bytes (recommended for NK/IK)
    size_t                  noiseServerStaticPublicKeyLength;
    const char             *noisePrologue; // optional prologue/context binding
} BFNetworkSecurity;

// Create a client-side secure connection over a datagram socket (future transports).
// The function does not take ownership of udpSocket. Returns NULL on failure.
BFNetworkConnection *BFNetworkConnectDatagram(BFNetworkTransport transport, int udpSocket, const struct sockaddr *server, socklen_t serverLength, const BFNetworkSecurity *security);

// Create a server-side secure connection over a datagram socket with a known peer
// (peer discovered by a cleartext datagram). Returns NULL on failure.
BFNetworkConnection *BFNetworkAcceptDatagram(BFNetworkTransport transport, int udpSocket, const struct sockaddr_storage *peer, socklen_t peerLength, const BFNetworkSecurity *security);

// I/O operations (blocking). Return number of bytes or BF_ERR (<0) on error.
int BFNetworkSend(BFNetworkConnection *networkConnection, const void *buffer, int length);
int BFNetworkReceive(BFNetworkConnection *networkConnection, void *buffer, int length);

// Close and free the connection.
void BFNetworkClose(BFNetworkConnection *networkConnection);

#ifdef BF_NOISE_TEST_HOOKS
// Test hook: resend the last frame sent over the NOISE transport for this connection.
// Returns bytes resent on success or BF_ERR on failure/unsupported transport.
int BFNetworkDebugResendLastFrame(BFNetworkConnection *networkConnection);
#endif

#ifdef __cplusplus
}
#endif

#endif // BF_NETWORK_H
