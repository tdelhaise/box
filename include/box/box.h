#ifndef BF_BOX_H
#define BF_BOX_H

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
static const uint16_t BFDefaultPort = 44444;
static const char *const BFDefaultAddress = "127.0.0.1";
static const size_t BFMaxDatagram    = 1200;   // taille max d'un datagramme UDP/DTLS

// -----------------------------------------------------------------------------
// Codes d'erreur génériques
// -----------------------------------------------------------------------------
enum {
    BF_OK  = 0,
    BF_ERR = -1
};

// -----------------------------------------------------------------------------
// Logging / helpers
// -----------------------------------------------------------------------------

// Macro simple de log
#define BFLog(fmt, ...) \
    fprintf(stderr, "[BOX ] " fmt "\\n", ##__VA_ARGS__)

#define BFError(fmt, ...) \
    fprintf(stderr, "[ERR ] " fmt "\\n", ##__VA_ARGS__)

#define BFWarn(fmt, ...) \
    fprintf(stderr, "[WARN] " fmt "\\n", ##__VA_ARGS__)


// Helper d'erreur fatale (arrête le programme avec perror)
void BFFatal(const char *message);

// -----------------------------------------------------------------------------
// API utilitaire
// -----------------------------------------------------------------------------

// Création socket UDP serveur (bind sur port)
// Retourne file descriptor ou <0 si erreur
int BFUdpServer(uint16_t port);

// Création socket UDP client (non connecté)
// Remplit sockaddr_in avec adresse/port cible
// Retourne file descriptor ou <0 si erreur
int BFUdpClient(const char *address, uint16_t port, struct sockaddr_in *outAddress);

// Lecture bloquante UDP
ssize_t BFUdpRecv(int fileDescriptor, void *buffet, size_t length, struct sockaddr *source, socklen_t *sourceLength);

// Écriture UDP
ssize_t BFUdpSend(int fileDescriptor, const void *buffet, size_t length, const struct sockaddr *destination, socklen_t destinationLength);

#ifdef __cplusplus
}
#endif

#endif // BF_BOX_H

