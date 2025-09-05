#include "box/dtls.h"
#include "box/box.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <stdlib.h>

#if OPENSSL_VERSION_NUMBER < 0x10100000L
#error "OpenSSL >= 1.1.0 required"
#endif

// -----------------------------------------------------------------------------
// Cookies (DoS mitigation)
// -----------------------------------------------------------------------------
static int generate_cookie(SSL *ssl, unsigned char *cookie, unsigned int *cookie_len) {
    static const char dummy[] = "box-cookie"; // TODO: remplacer par HMAC(secret, peer)
    memcpy(cookie, dummy, sizeof(dummy));
    *cookie_len = (unsigned int)sizeof(dummy);
    return 1;
}

static int verify_cookie(SSL *ssl, const unsigned char *cookie, unsigned int cookie_len) {
    // TODO: vérifier correctement le cookie (recalculer et comparer)
    (void)ssl; (void)cookie; (void)cookie_len;
    return 1;
}

// -----------------------------------------------------------------------------
// PSK callbacks (optionnels, activés avec -DBOX_USE_PSK=ON)
// -----------------------------------------------------------------------------
static int psk_server_cb(SSL *ssl, const char *identity, unsigned char *psk, unsigned int max_psk_len) {
#ifdef BOX_USE_PSK
    (void)ssl;
    const char *expected_id = "box-client";
    static const unsigned char key[] = { 's','e','c','r','e','t','p','s','k' };

    if (!identity || strcmp(identity, expected_id) != 0)
        return 0;
    if (sizeof(key) > max_psk_len) return 0;
    memcpy(psk, key, sizeof(key));
    return (unsigned int)sizeof(key);
#else
    (void)ssl; (void)identity; (void)psk; (void)max_psk_len;
    return 0;
#endif
}

static unsigned int psk_client_cb(SSL *ssl, const char *hint, char *identity, unsigned int max_identity_len, unsigned char *psk, unsigned int max_psk_len) {
#ifdef BOX_USE_PSK
    (void)ssl; (void)hint;
    const char *id = "box-client";
    static const unsigned char key[] = { 's','e','c','r','e','t','p','s','k' };

    if (strlen(id) + 1 > max_identity_len) return 0;
    strcpy(identity, id);

    if (sizeof(key) > max_psk_len) return 0;
    memcpy(psk, key, sizeof(key));
    return (unsigned int)sizeof(key);
#else
    (void)ssl; (void)hint; (void)identity; (void)max_identity_len; (void)psk; (void)max_psk_len;
    return 0;
#endif
}

// -----------------------------------------------------------------------------
// Contexte SSL_CTX
// -----------------------------------------------------------------------------
static SSL_CTX *make_ctx(int is_server, const box_dtls_config_t *cfg) {
    OPENSSL_init_ssl(0, NULL);
    const SSL_METHOD *m = DTLS_method();
    SSL_CTX *ctx = SSL_CTX_new(m);
    if (!ctx) return NULL;

    // Forcer DTLS 1.2 uniquement
#ifdef DTLS1_2_VERSION
    SSL_CTX_set_min_proto_version(ctx, DTLS1_2_VERSION);
    SSL_CTX_set_max_proto_version(ctx, DTLS1_2_VERSION);
#endif

    // Liste de ciphers
    if (cfg && cfg->cipher_list) {
        SSL_CTX_set_cipher_list(ctx, cfg->cipher_list);
    } else {
        SSL_CTX_set_cipher_list(ctx,
            "ECDHE-ECDSA-AES128-GCM-SHA256:"
            "ECDHE-RSA-AES128-GCM-SHA256:"
            "PSK-AES128-GCM-SHA256");
    }

    if (is_server) {
        SSL_CTX_set_cookie_generate_cb(ctx, generate_cookie);
        SSL_CTX_set_cookie_verify_cb(ctx, verify_cookie);
    }

    // Sélection Certs ou PSK
    int using_psk = 0;
#ifdef BOX_USE_PSK
    using_psk = 1;
#endif
    if (cfg && cfg->cert_file && cfg->key_file) using_psk = 0;
    if (cfg && cfg->psk_identity && cfg->psk_key && cfg->psk_key_len) using_psk = 1;

    if (using_psk) {
        if (is_server) {
            SSL_CTX_use_psk_identity_hint(ctx, "boxd");
            SSL_CTX_set_psk_server_callback(ctx, psk_server_cb);
        } else {
            SSL_CTX_set_psk_client_callback(ctx, psk_client_cb);
        }
    } else {
        const char *cert = (cfg && cfg->cert_file) ? cfg->cert_file : "server.pem";
        const char *key  = (cfg && cfg->key_file)  ? cfg->key_file  : "server.key";
        if (SSL_CTX_use_certificate_file(ctx, cert, SSL_FILETYPE_PEM) <= 0) {
            perror("SSL_CTX_use_certificate_file");
        }
        if (SSL_CTX_use_PrivateKey_file(ctx, key, SSL_FILETYPE_PEM) <= 0) {
            perror("SSL_CTX_use_PrivateKey_file");
        }
    }

    return ctx;
}

// -----------------------------------------------------------------------------
// Création de session DTLS
// -----------------------------------------------------------------------------
static box_dtls_t *dtls_new_common(int fd, int is_server, const box_dtls_config_t *cfg) {
    SSL_CTX *ctx = make_ctx(is_server, cfg);
    if (!ctx) return NULL;

    box_dtls_t *d = calloc(1, sizeof(*d));
    if (!d) { SSL_CTX_free(ctx); return NULL; }

    d->ctx = ctx;
    d->fd  = fd;

    d->ssl = SSL_new(ctx);
    if (!d->ssl) { box_dtls_free(d); return NULL; }

    d->bio = BIO_new_dgram(fd, BIO_NOCLOSE);
    if (!d->bio) { box_dtls_free(d); return NULL; }

    SSL_set_bio(d->ssl, d->bio, d->bio);
    if (is_server) SSL_set_accept_state(d->ssl);
    else           SSL_set_connect_state(d->ssl);

    BIO_ctrl(d->bio, BIO_CTRL_DGRAM_SET_MTU, BOX_MAX_DGRAM, NULL);
    return d;
}

// -----------------------------------------------------------------------------
// API publique
// -----------------------------------------------------------------------------
box_dtls_t *box_dtls_server_new_ex(int udp_fd, const box_dtls_config_t *cfg) {
    return dtls_new_common(udp_fd, 1, cfg);
}
box_dtls_t *box_dtls_client_new_ex(int udp_fd, const box_dtls_config_t *cfg) {
    return dtls_new_common(udp_fd, 0, cfg);
}

box_dtls_t *box_dtls_server_new(int udp_fd) {
    return box_dtls_server_new_ex(udp_fd, NULL);
}
box_dtls_t *box_dtls_client_new(int udp_fd) {
    return box_dtls_client_new_ex(udp_fd, NULL);
}

int box_dtls_handshake_server(box_dtls_t *dtls, struct sockaddr_storage *peer, socklen_t peerlen) {
    if (!dtls) return BOX_ERR;
    BIO_ctrl(dtls->bio, BIO_CTRL_DGRAM_SET_CONNECTED, 0, peer);

    int ret = SSL_do_handshake(dtls->ssl);
    if (ret == 1) return BOX_OK;
    return BOX_ERR; // TODO: gérer WANT_READ/WRITE + retransmissions
}

int box_dtls_handshake_client(box_dtls_t *dtls, const struct sockaddr *srv, socklen_t srvlen) {
    if (!dtls) return BOX_ERR;
    if (connect(dtls->fd, srv, srvlen) < 0) return BOX_ERR;
    BIO_ctrl(dtls->bio, BIO_CTRL_DGRAM_SET_CONNECTED, 0, NULL);

    int ret = SSL_do_handshake(dtls->ssl);
    if (ret == 1) return BOX_OK;
    return BOX_ERR;
}

int box_dtls_send(box_dtls_t *dtls, const void *buf, int len) {
    if (!dtls) return BOX_ERR;
    return SSL_write(dtls->ssl, buf, len);
}

int box_dtls_recv(box_dtls_t *dtls, void *buf, int len) {
    if (!dtls) return BOX_ERR;
    return SSL_read(dtls->ssl, buf, len);
}

void box_dtls_free(box_dtls_t *dtls) {
    if (!dtls) return;
    if (dtls->ssl) SSL_free(dtls->ssl);
    if (dtls->ctx) SSL_CTX_free(dtls->ctx);
    free(dtls);
}

