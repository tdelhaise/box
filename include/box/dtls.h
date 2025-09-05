#ifndef BOX_DTLS_H
#define BOX_DTLS_H

#include <openssl/ssl.h>
#include <netinet/in.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct box_dtls {
SSL_CTX *ctx;
SSL *ssl;
BIO *bio; // datagram BIO
int fd; // UDP socket
} box_dtls_t;

// Configuration DTLS (certificats ou PSK)
typedef struct box_dtls_config {
// Si non-NULL, chemins cert/clé PEM (mode certificats)
const char *cert_file; // ex: "server.pem"
const char *key_file; // ex: "server.key"

// Mode PSK si défini (ignoré si cert_file/key_file non NULL)
const char *psk_identity; // ex: "box-client"
const unsigned char *psk_key; // binaire
size_t psk_key_len; // longueur clé

// Ciphers DTLS 1.2 (liste OpenSSL style). Ex: "TLS_AES_128_GCM_SHA256" (TLS1.3) ne s'applique pas à DTLS1.2;
// Utiliser par ex: "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:PSK-AES128-GCM-SHA256"
const char *cipher_list;
} box_dtls_config_t;

// Création contextes
box_dtls_t *box_dtls_server_new_ex(int udp_fd, const box_dtls_config_t *cfg);
box_dtls_t *box_dtls_client_new_ex(int udp_fd, const box_dtls_config_t *cfg);

// Raccourcis (utilisent certificats par défaut si présents au cwd)
box_dtls_t *box_dtls_server_new(int udp_fd);
box_dtls_t *box_dtls_client_new(int udp_fd);

// Handshake (attache l'adresse pair)
int box_dtls_handshake_server(box_dtls_t *dtls, struct sockaddr_storage *peer, socklen_t peerlen);
int box_dtls_handshake_client(box_dtls_t *dtls, const struct sockaddr *srv, socklen_t srvlen);

// E/S chiffrées
int box_dtls_send(box_dtls_t *dtls, const void *buf, int len);
int box_dtls_recv(box_dtls_t *dtls, void *buf, int len);

// Libération
void box_dtls_free(box_dtls_t *dtls);

#ifdef __cplusplus
}
#endif

#endif // BOX_DTLS_H
