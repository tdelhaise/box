#include "box/dtls.h"
#include "box/box.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>
#include <arpa/inet.h>

#include <openssl/hmac.h>
#include <openssl/evp.h>
#include <openssl/rand.h>

#if OPENSSL_VERSION_NUMBER < 0x10100000L
#error "OpenSSL >= 1.1.0 required"
#endif

// ============================================================================
// Cookie secret (HMAC) — initialisé une fois. Optionnellement via env BOX_COOKIE_SECRET.
// ============================================================================
static unsigned char g_cookie_secret[32];
static int g_cookie_secret_inited = 0;

static void init_cookie_secret(void) {
    if (g_cookie_secret_inited) return;

    const char *env = getenv("BOX_COOKIE_SECRET");
    if (env && *env) {
        // Tronque/pad à 32 octets
        size_t elen = strlen(env);
        memset(g_cookie_secret, 0, sizeof(g_cookie_secret));
        memcpy(g_cookie_secret, env, elen > sizeof(g_cookie_secret) ? sizeof(g_cookie_secret) : elen);
        g_cookie_secret_inited = 1;
        return;
    }
    // Sinon tirage aléatoire
    if (RAND_bytes(g_cookie_secret, (int)sizeof(g_cookie_secret)) == 1) {
        g_cookie_secret_inited = 1;
    } else {
        // Fallback déterministe (développement) — à éviter en prod
        static const unsigned char fallback[] = "box-cookie-fallback-secret-please-set-env";
        memset(g_cookie_secret, 0, sizeof(g_cookie_secret));
        memcpy(g_cookie_secret, fallback, sizeof(g_cookie_secret));
        g_cookie_secret_inited = 1;
    }
}

// Récupère l'adresse/port du pair (depuis le BIO datagram)
static int get_peer_addr(SSL *ssl, struct sockaddr_storage *peer, socklen_t *peerlen) {
    if (!ssl || !peer || !peerlen) return 0;
    BIO *rbio = SSL_get_rbio(ssl);
    if (!rbio) return 0;
    memset(peer, 0, sizeof(*peer));
    *peerlen = sizeof(*peer);
    long ok = BIO_ctrl(rbio, BIO_CTRL_DGRAM_GET_PEER, 0, peer);
    return ok > 0;
}

// Construit un buffer canonique addr|port pour HMAC
static int peer_to_bytes(const struct sockaddr_storage *peer, unsigned char *out, size_t *outlen) {
    if (!peer || !out || !outlen) return 0;

    unsigned char *p = out;
    size_t left = *outlen;

    if (peer->ss_family == AF_INET) {
        const struct sockaddr_in *sin = (const struct sockaddr_in*)peer;
        if (left < 1 + 4 + 2) return 0;
        *p++ = 4; // v4 tag
        memcpy(p, &sin->sin_addr.s_addr, 4); p += 4;
        memcpy(p, &sin->sin_port, 2); p += 2;
    } else if (peer->ss_family == AF_INET6) {
        const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6*)peer;
        if (left < 1 + 16 + 2) return 0;
        *p++ = 6; // v6 tag
        memcpy(p, &sin6->sin6_addr, 16); p += 16;
        memcpy(p, &sin6->sin6_port, 2); p += 2;
    } else {
        return 0;
    }

    *outlen = (size_t)(p - out);
    return 1;
}

// Cookie = HMAC-SHA256(secret, peer_bytes) (tronqué à la taille du buffer de sortie)
static int make_cookie_for_peer(const struct sockaddr_storage *peer,
                                unsigned char *cookie, unsigned int *cookie_len) {
    init_cookie_secret();

    unsigned char peer_bytes[32];
    size_t peer_len = sizeof(peer_bytes);
    if (!peer_to_bytes(peer, peer_bytes, &peer_len)) return 0;

    unsigned int md_len = 0;
    unsigned char md[EVP_MAX_MD_SIZE];

    if (!HMAC(EVP_sha256(), g_cookie_secret, (int)sizeof(g_cookie_secret),
              peer_bytes, peer_len, md, &md_len)) {
        return 0;
    }

    unsigned int need = md_len;
    if (need > *cookie_len) need = *cookie_len; // tronque si nécessaire
    memcpy(cookie, md, need);
    *cookie_len = need;
    return 1;
}

// -----------------------------------------------------------------------------
// DTLS Cookie Callbacks (DoS mitigation)
// -----------------------------------------------------------------------------
static int generate_cookie(SSL *ssl, unsigned char *cookie, unsigned int *cookie_len) {
    struct sockaddr_storage peer;
    socklen_t peerlen;
    if (!get_peer_addr(ssl, &peer, &peerlen)) return 0;

    unsigned int maxlen = *cookie_len;
    *cookie_len = 32; // taille souhaitée (<= maxlen)
    if (*cookie_len > maxlen) *cookie_len = maxlen;

    return make_cookie_for_peer(&peer, cookie, cookie_len);
}

static int verify_cookie(SSL *ssl, const unsigned char *cookie, unsigned int cookie_len) {
    struct sockaddr_storage peer;
    socklen_t peerlen;
    if (!get_peer_addr(ssl, &peer, &peerlen)) return 0;

    unsigned char expected[64];
    unsigned int exp_len = sizeof(expected);
    if (!make_cookie_for_peer(&peer, expected, &exp_len)) return 0;

    if (cookie_len != exp_len) return 0;
    // comparaison constante
    unsigned int diff = 0;
    for (unsigned int i = 0; i < cookie_len; ++i) diff |= (cookie[i] ^ expected[i]);
    return diff == 0;
}

// -----------------------------------------------------------------------------
// PSK callbacks (si -DBOX_USE_PSK=ON)
// -----------------------------------------------------------------------------
static unsigned int psk_server_cb(SSL *ssl, const char *identity, unsigned char *psk, unsigned int max_psk_len) {
#ifdef BOX_USE_PSK
    (void)ssl;
    const char *expected_id = "box-client";
    static const unsigned char key[] = { 's','e','c','r','e','t','p','s','k' };

    if (!identity || strcmp(identity, expected_id) != 0) return 0;
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
// SSL_CTX factory
// -----------------------------------------------------------------------------
static SSL_CTX *make_ctx(int is_server, const box_dtls_config_t *cfg) {
    OPENSSL_init_ssl(0, NULL);
    const SSL_METHOD *m = DTLS_method();
    SSL_CTX *ctx = SSL_CTX_new(m);
    if (!ctx) return NULL;

#ifdef DTLS1_2_VERSION
    SSL_CTX_set_min_proto_version(ctx, DTLS1_2_VERSION);
    SSL_CTX_set_max_proto_version(ctx, DTLS1_2_VERSION);
#endif

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
        // TODO (prod): charger CA, activer SSL_VERIFY_PEER côté client
    }

    return ctx;
}

// -----------------------------------------------------------------------------
// Session helpers
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

box_dtls_t *box_dtls_server_new(int udp_fd) { return box_dtls_server_new_ex(udp_fd, NULL); }
box_dtls_t *box_dtls_client_new(int udp_fd) { return box_dtls_client_new_ex(udp_fd, NULL); }

int box_dtls_handshake_server(box_dtls_t *dtls, struct sockaddr_storage *peer, socklen_t peerlen) {
    if (!dtls) return BOX_ERR;
    BIO_ctrl(dtls->bio, BIO_CTRL_DGRAM_SET_CONNECTED, 0, peer);

    int ret = SSL_do_handshake(dtls->ssl);
    if (ret == 1) return BOX_OK;
    // TODO: gérer WANT_READ/WRITE + timers (DTLSv1_handle_timeout)
    return BOX_ERR;
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

