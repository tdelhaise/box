#ifndef BF_DTLS_H
#define BF_DTLS_H

#include <openssl/ssl.h>
#include <netinet/in.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BFDtls {
SSL_CTX *context;
SSL *ssl;
BIO *bio; // datagram BIO
int fileDescriptor; // UDP socket
} BFDtls;

// Configuration DTLS (certificats ou PSK)
typedef struct BFDtlsConfig {
// Si non-NULL, chemins cert/clé PEM (mode certificats)
const char *certificateFile; // ex: "server.pem"
const char *keyFile; // ex: "server.key"

// Mode PSK si défini (ignoré si certificateFile/keyFile non NULL)
const char *pskIdentity; // ex: "box-client"
const unsigned char *pskKey; // binaire
size_t pskKeyLength; // longueur clé

// Ciphers DTLS 1.2 (liste OpenSSL style). Ex: "TLS_AES_128_GCM_SHA256" (TLS1.3) ne s'applique pas à DTLS1.2;
// Utiliser par ex: "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:PSK-AES128-GCM-SHA256"
const char *cipherList;
} BFDtlsConfig;

// Création contextes
BFDtls *BFDtlsServerNewEx(int udpFileDescriptor, const BFDtlsConfig *config);
BFDtls *BFDtlsClientNewEx(int udpFileDescriptor, const BFDtlsConfig *config);

// Raccourcis (utilisent certificats par défaut si présents au cwd)
BFDtls *BFDtlsServerNew(int udpFileDescriptor);
BFDtls *BFDtlsClientNew(int udpFileDescriptor);

// Handshake (attache l'adresse pair)
int BFDtlsHandshakeServer(BFDtls *dtls, struct sockaddr_storage *peer, socklen_t peerLength);
int BFDtlsHandshakeClient(BFDtls *dtls, const struct sockaddr *server, socklen_t serverLength);

// E/S chiffrées
int BFDtlsSend(BFDtls *dtls, const void *buffet, int length);
int BFDtlsRecv(BFDtls *dtls, void *buffet, int length);

// Libération
void BFDtlsFree(BFDtls *dtls);

#ifdef __cplusplus
}
#endif

#endif // BF_DTLS_H
