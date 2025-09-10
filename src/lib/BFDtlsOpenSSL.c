#include "box/BFCommon.h"
#include "box/BFDtls.h"
#include "box/BFMemory.h"

#include <arpa/inet.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <unistd.h>

#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/rand.h>
#include <openssl/x509v3.h>

#if OPENSSL_VERSION_NUMBER < 0x10100000L
#error "OpenSSL >= 1.1.0 required"
#endif

// ============================================================================
// Cookie secret (HMAC) — initialisé une fois. Optionnellement via env BOX_COOKIE_SECRET.
// ============================================================================
static unsigned char g_cookie_secret[32];
static int           g_cookie_secret_inited = 0;

static void init_cookie_secret(void) {
    if (g_cookie_secret_inited)
        return;

    const char *env = getenv("BOX_COOKIE_SECRET");
    if (env && *env) {
        // Tronque/pad à 32 octets
        size_t elen = strlen(env);
        memset(g_cookie_secret, 0, sizeof(g_cookie_secret));
        memcpy(g_cookie_secret, env,
               elen > sizeof(g_cookie_secret) ? sizeof(g_cookie_secret) : elen);
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
    if (!ssl || !peer || !peerlen)
        return 0;
    BIO *rbio = SSL_get_rbio(ssl);
    if (!rbio)
        return 0;
    memset(peer, 0, sizeof(*peer));
    *peerlen = sizeof(*peer);
    long ok  = BIO_ctrl(rbio, BIO_CTRL_DGRAM_GET_PEER, 0, peer);
    return ok > 0;
}

// Construit un buffer canonique address|port pour HMAC
static int peer_to_bytes(const struct sockaddr_storage *peer, unsigned char *out, size_t *outlen) {
    if (!peer || !out || !outlen)
        return 0;

    unsigned char *p    = out;
    size_t         left = *outlen;

    if (peer->ss_family == AF_INET) {
        const struct sockaddr_in *sin = (const struct sockaddr_in *)peer;
        if (left < 1 + 4 + 2)
            return 0;
        *p++ = 4; // v4 tag
        memcpy(p, &sin->sin_addr.s_addr, 4);
        p += 4;
        memcpy(p, &sin->sin_port, 2);
        p += 2;
    } else if (peer->ss_family == AF_INET6) {
        const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)peer;
        if (left < 1 + 16 + 2)
            return 0;
        *p++ = 6; // v6 tag
        memcpy(p, &sin6->sin6_addr, 16);
        p += 16;
        memcpy(p, &sin6->sin6_port, 2);
        p += 2;
    } else {
        return 0;
    }

    *outlen = (size_t)(p - out);
    return 1;
}

// Cookie = HMAC-SHA256(secret, peer_bytes) (tronqué à la taille du buffer de sortie)
static int make_cookie_for_peer(const struct sockaddr_storage *peer, unsigned char *cookie,
                                unsigned int *cookie_len) {
    init_cookie_secret();

    unsigned char peer_bytes[32];
    size_t        peer_len = sizeof(peer_bytes);
    if (!peer_to_bytes(peer, peer_bytes, &peer_len))
        return 0;

    unsigned int  md_len = 0;
    unsigned char md[EVP_MAX_MD_SIZE];

    if (!HMAC(EVP_sha256(), g_cookie_secret, (int)sizeof(g_cookie_secret), peer_bytes, peer_len, md,
              &md_len)) {
        return 0;
    }

    unsigned int need = md_len;
    if (need > *cookie_len)
        need = *cookie_len; // tronque si nécessaire
    memcpy(cookie, md, need);
    *cookie_len = need;
    return 1;
}

static int generate_cookie(SSL *ssl, unsigned char *cookie, unsigned int *cookie_len) {
    struct sockaddr_storage peer;
    socklen_t               peer_len = sizeof(peer);
    if (!get_peer_addr(ssl, &peer, &peer_len))
        return 0;
    return make_cookie_for_peer(&peer, cookie, cookie_len);
}

static int verify_cookie(SSL *ssl, const unsigned char *cookie, unsigned int cookie_len) {
    struct sockaddr_storage peer;
    socklen_t               peer_len = sizeof(peer);
    unsigned char           expected[64];
    unsigned int            exp_len = sizeof(expected);
    if (!get_peer_addr(ssl, &peer, &peer_len))
        return 0;
    if (!make_cookie_for_peer(&peer, expected, &exp_len))
        return 0;

    if (cookie_len != exp_len)
        return 0;
    // comparaison constante
    unsigned int diff = 0;
    for (unsigned int i = 0; i < cookie_len; ++i)
        diff |= (cookie[i] ^ expected[i]);
    return diff == 0;
}

// -----------------------------------------------------------------------------
// PreShareKey callbacks (si -DBOX_USE_PRESHAREKEY=ON)
// -----------------------------------------------------------------------------
static unsigned int pre_share_key_server_cb(SSL *ssl, const char *identity,
                                            unsigned char *preShareKey,
                                            unsigned int   max_preShareKey_len) {
#ifdef BOX_USE_PRESHAREKEY
    (void)ssl;
    const char                *expected_id = "box-client";
    static const unsigned char key[]       = {'s', 'e', 'c', 'r', 'e', 't', 'p', 's', 'k'};

    if (!identity || strcmp(identity, expected_id) != 0)
        return 0;
    if (sizeof(key) > max_preShareKey_len)
        return 0;
    memcpy(preShareKey, key, sizeof(key));
    return (unsigned int)sizeof(key);
#else
    (void)ssl;
    (void)identity;
    (void)preShareKey;
    (void)max_preShareKey_len;
    return 0;
#endif
}

static unsigned int pre_share_key_client_cb(SSL *ssl, const char *hint, char *identity,
                                            unsigned int   max_identity_len,
                                            unsigned char *preShareKey,
                                            unsigned int   max_preShareKey_len) {
#ifdef BOX_USE_PRESHAREKEY
    (void)ssl;
    (void)hint;
    const char                *id    = "box-client";
    static const unsigned char key[] = {'s', 'e', 'c', 'r', 'e', 't', 'p', 's', 'k'};

    if (strlen(id) + 1 > max_identity_len)
        return 0;
    strcpy(identity, id);
    if (sizeof(key) > max_preShareKey_len)
        return 0;
    memcpy(preShareKey, key, sizeof(key));
    return (unsigned int)sizeof(key);
#else
    (void)ssl;
    (void)hint;
    (void)identity;
    (void)max_identity_len;
    (void)preShareKey;
    (void)max_preShareKey_len;
    return 0;
#endif
}

// -----------------------------------------------------------------------------
// SSL_CTX factory
// -----------------------------------------------------------------------------
static SSL_CTX *make_ctx(int is_server, const BFDtlsConfig *config) {
    OPENSSL_init_ssl(0, NULL);
    const SSL_METHOD *m       = DTLS_method();
    SSL_CTX          *context = SSL_CTX_new(m);
    if (!context)
        return NULL;

#ifdef DTLS1_2_VERSION
    SSL_CTX_set_min_proto_version(context, DTLS1_2_VERSION);
    SSL_CTX_set_max_proto_version(context, DTLS1_2_VERSION);
#endif

    if (config && config->cipherList) {
        SSL_CTX_set_cipher_list(context, config->cipherList);
    } else {
        SSL_CTX_set_cipher_list(context, "ECDHE-ECDSA-AES128-GCM-SHA256:"
                                         "ECDHE-RSA-AES128-GCM-SHA256:"
                                         "PSK-AES128-GCM-SHA256");
    }

    if (is_server) {
        SSL_CTX_set_cookie_generate_cb(context, generate_cookie);
        SSL_CTX_set_cookie_verify_cb(context, verify_cookie);
    }

    int using_preShareKey = 0;
#ifdef BOX_USE_PRESHAREKEY
    using_preShareKey = 1;
#endif
    if (config && config->certificateFile && config->keyFile) {
        using_preShareKey = 0;
    }

    if (config && config->preShareKeyIdentity && config->preShareKey && config->preShareKeyLength) {
        using_preShareKey = 1;
    }

    if (using_preShareKey) {
        if (is_server) {
            SSL_CTX_use_psk_identity_hint(context, "boxd");
            SSL_CTX_set_psk_server_callback(context, pre_share_key_server_cb);
        } else {
            SSL_CTX_set_psk_client_callback(context, pre_share_key_client_cb);
        }
    } else {
        const char *cert =
            (config && config->certificateFile) ? config->certificateFile : "server.pem";
        const char *key = (config && config->keyFile) ? config->keyFile : "server.key";
        if (SSL_CTX_use_certificate_file(context, cert, SSL_FILETYPE_PEM) <= 0) {
            perror("SSL_CTX_use_certificate_file");
        }
        if (SSL_CTX_use_PrivateKey_file(context, key, SSL_FILETYPE_PEM) <= 0) {
            perror("SSL_CTX_use_PrivateKey_file");
        }
        // Client certificate verification defaults (load CA + verify peer)
        if (!is_server) {
            int         ok     = 0;
            const char *cafile = getenv("BOX_CA_FILE");
            const char *capath = getenv("BOX_CA_PATH");
            if (cafile || capath) {
                ok = SSL_CTX_load_verify_locations(context, cafile, capath);
            }
            if (!ok) {
                SSL_CTX_set_default_verify_paths(context);
            }
            SSL_CTX_set_verify(context, SSL_VERIFY_PEER, NULL);
            SSL_CTX_set_verify_depth(context, 4);

            const char *expectedHost = getenv("BOX_EXPECTED_HOST");
            if (expectedHost && *expectedHost) {
                X509_VERIFY_PARAM *param = SSL_CTX_get0_param(context);
                /* No partial wildcard by default */
                X509_VERIFY_PARAM_set_hostflags(param, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);
                X509_VERIFY_PARAM_set1_host(param, expectedHost, 0);
            }
        }
    }

    return context;
}

// -----------------------------------------------------------------------------
// Session helpers
// -----------------------------------------------------------------------------
static BFDtls *dtls_new_common(int fileDescriptor, int is_server, const BFDtlsConfig *config) {
    SSL_CTX *context = make_ctx(is_server, config);
    if (!context)
        return NULL;

    BFDtls *d = (BFDtls *)BFMemoryAllocate(sizeof(*d));
    if (!d) {
        SSL_CTX_free(context);
        return NULL;
    }

    d->context        = context;
    d->fileDescriptor = fileDescriptor;

    d->ssl = SSL_new(context);
    if (!d->ssl) {
        BFDtlsFree(d);
        return NULL;
    }

    d->bio = BIO_new_dgram(fileDescriptor, BIO_NOCLOSE);
    if (!d->bio) {
        BFDtlsFree(d);
        return NULL;
    }

    SSL_set_bio(d->ssl, d->bio, d->bio);
    if (is_server)
        SSL_set_accept_state(d->ssl);
    else
        SSL_set_connect_state(d->ssl);

    BIO_ctrl(d->bio, BIO_CTRL_DGRAM_SET_MTU, BFMaxDatagram, NULL);
    return d;
}

static int wait_fd_ready(int fd, int want_write, const struct timeval *timeout) {
    fd_set rfds;
    fd_set wfds;
    FD_ZERO(&rfds);
    FD_ZERO(&wfds);
    if (want_write) {
        FD_SET(fd, &wfds);
    } else {
        FD_SET(fd, &rfds);
    }
    // select modifies the timeout; make a local copy if provided
    struct timeval  tv_copy;
    struct timeval *ptv = NULL;
    if (timeout != NULL) {
        tv_copy = *timeout;
        ptv     = &tv_copy;
    }
    int r = select(fd + 1, want_write ? NULL : &rfds, want_write ? &wfds : NULL, NULL, ptv);
    if (r < 0 && errno == EINTR)
        return 0; // treat as timeout/continue
    return r;
}

static int dtls_handle_want(BFDtls *dtls, int want_write) {
    // Check if DTLS has an active retransmit timer and wait accordingly
    struct timeval tv;
    int            have_timer = DTLSv1_get_timeout(dtls->ssl, &tv);
    int            sel = wait_fd_ready(dtls->fileDescriptor, want_write, have_timer ? &tv : NULL);
    if (sel == 0) {
        // timeout -> let OpenSSL handle internal DTLS retransmit
        (void)DTLSv1_handle_timeout(dtls->ssl);
        return 0; // continue
    }
    if (sel < 0) {
        return -1; // error
    }
    return 0; // ready, retry operation
}

// -----------------------------------------------------------------------------
// API publique
// -----------------------------------------------------------------------------
BFDtls *BFDtlsServerNewEx(int udpFileDescriptor, const BFDtlsConfig *config) {
    return dtls_new_common(udpFileDescriptor, 1, config);
}
BFDtls *BFDtlsClientNewEx(int udpFileDescriptor, const BFDtlsConfig *config) {
    return dtls_new_common(udpFileDescriptor, 0, config);
}

BFDtls *BFDtlsServerNew(int udpFileDescriptor) {
    return BFDtlsServerNewEx(udpFileDescriptor, NULL);
}
BFDtls *BFDtlsClientNew(int udpFileDescriptor) {
    return BFDtlsClientNewEx(udpFileDescriptor, NULL);
}

int BFDtlsHandshakeServer(BFDtls *dtls, struct sockaddr_storage *peer, socklen_t peerLength) {
    (void)peerLength;
    if (!dtls)
        return BF_ERR;
    BIO_ctrl(dtls->bio, BIO_CTRL_DGRAM_SET_CONNECTED, 0, peer);

    // Perform blocking handshake with DTLS timers and retransmissions
    unsigned int timeouts = 0;
    for (;;) {
        int ret = SSL_do_handshake(dtls->ssl);
        if (ret == 1)
            return BF_OK;

        int err = SSL_get_error(dtls->ssl, ret);
        if (err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE) {
            int r = dtls_handle_want(dtls, err == SSL_ERROR_WANT_WRITE);
            if (r < 0)
                return BF_ERR;
            if (r == 0) {
                // Count retransmit timeouts to avoid infinite loops
                timeouts++;
                if (timeouts > 8)
                    return BF_ERR;
            }
            continue; // retry handshake
        }
        return BF_ERR;
    }
}

int BFDtlsHandshakeClient(BFDtls *dtls, const struct sockaddr *server, socklen_t serverLength) {
    if (!dtls) {
        perror("dtls handle is null");
        return BF_ERR;
    }

    if (connect(dtls->fileDescriptor, server, serverLength) < 0) {
        perror("failed to connect to server");
        return BF_ERR;
    }

    BIO_ctrl(dtls->bio, BIO_CTRL_DGRAM_SET_CONNECTED, 0, NULL);

    // Blocking handshake with DTLS timers
    unsigned int timeouts = 0;
    for (;;) {
        int ret = SSL_do_handshake(dtls->ssl);
        if (ret == 1)
            return BF_OK;

        int err = SSL_get_error(dtls->ssl, ret);
        if (err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE) {
            int r = dtls_handle_want(dtls, err == SSL_ERROR_WANT_WRITE);
            if (r < 0)
                return BF_ERR;
            if (r == 0) {
                timeouts++;
                if (timeouts > 8)
                    return BF_ERR;
            }
            continue;
        }
        return BF_ERR;
    }
}

int BFDtlsSend(BFDtls *dtls, const void *buffet, int length) {
    if (!dtls)
        return BF_ERR;
    for (;;) {
        int n = SSL_write(dtls->ssl, buffet, length);
        if (n > 0)
            return n;
        int err = SSL_get_error(dtls->ssl, n);
        if (err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE) {
            int r = dtls_handle_want(dtls, err == SSL_ERROR_WANT_WRITE);
            if (r < 0)
                return BF_ERR;
            continue; // retry
        }
        return BF_ERR;
    }
}

int BFDtlsRecv(BFDtls *dtls, void *buffet, int length) {
    if (!dtls)
        return BF_ERR;
    for (;;) {
        int n = SSL_read(dtls->ssl, buffet, length);
        if (n > 0)
            return n;
        int err = SSL_get_error(dtls->ssl, n);
        if (err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE) {
            int r = dtls_handle_want(dtls, err == SSL_ERROR_WANT_WRITE);
            if (r < 0)
                return BF_ERR;
            continue; // retry
        }
        return BF_ERR;
    }
}

void BFDtlsFree(BFDtls *dtls) {
    if (!dtls)
        return;
    if (dtls->ssl)
        SSL_free(dtls->ssl);
    if (dtls->context)
        SSL_CTX_free(dtls->context);
    BFMemoryRelease(dtls);
}
