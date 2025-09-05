#ifndef BOX_BOX_H
#define BOX_BOX_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <netinet/in.h>

#ifdef __cplusplus
extern "C" {
#endif

// -----------------------------------------------------------------------------
// Constantes globales
// -----------------------------------------------------------------------------
#define BOX_DEFAULT_PORT 44444
#define BOX_DEFAULT_ADDR "127.0.0.1"
#define BOX_MAX_DGRAM    1200   // taille max d'un datagramme UDP/DTLS

// -----------------------------------------------------------------------------
// Codes d'erreur génériques
// -----------------------------------------------------------------------------
enum {
    BOX_OK  = 0,
    BOX_ERR = -1
};

// -----------------------------------------------------------------------------
// Logging / helpers
// -----------------------------------------------------------------------------

// Macro simple de log
#define BOX_LOG(fmt, ...) \
    fprintf(stderr, "[box] " fmt "\\n", ##__VA_ARGS__)

// Helper d'erreur fatale (arrête le programme avec perror)
void box_fatal(const char *msg);

// -----------------------------------------------------------------------------
// API utilitaire
// -----------------------------------------------------------------------------

// Création socket UDP serveur (bind sur port)
// Retourne fd ou <0 si erreur
int box_udp_server(uint16_t port);

// Création socket UDP client (non connecté)
// Remplit sockaddr_in avec adresse/port cible
// Retourne fd ou <0 si erreur
int box_udp_client(const char *addr, uint16_t port, struct sockaddr_in *out);

// Lecture bloquante UDP
ssize_t box_udp_recv(int fd, void *buf, size_t len, struct sockaddr *src, socklen_t *srclen);

// Écriture UDP
ssize_t box_udp_send(int fd, const void *buf, size_t len, const struct sockaddr *dst, socklen_t dstlen);

#ifdef __cplusplus
}
#endif

#endif // BOX_BOX_H

