#ifndef BF_COMMON_H
#define BF_COMMON_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#ifdef __cplusplus
extern "C" {
#endif

// -----------------------------------------------------------------------------
// Constantes globales
// -----------------------------------------------------------------------------
static const uint16_t    BFDefaultPort    = 12567;
static const char *const BFDefaultAddress = "127.0.0.1";
static const size_t      BFMaxDatagram    = 1200; // taille max d'un datagramme UDP/DTLS

// -----------------------------------------------------------------------------
// Codes d'erreur génériques
// -----------------------------------------------------------------------------
enum { BF_OK = 0, BF_ERR = -1 };

// -----------------------------------------------------------------------------
// Logging / helpers
// -----------------------------------------------------------------------------

// Macro simple de log
#define BFLog(fmt, ...) fprintf(stderr, "[BOX ] " fmt "\n", ##__VA_ARGS__)

#define BFError(fmt, ...) fprintf(stderr, "[ERR ] " fmt "\n", ##__VA_ARGS__)

#define BFWarn(fmt, ...) fprintf(stderr, "[WARN] " fmt "\n", ##__VA_ARGS__)

// Helper d'erreur fatale (arrête le programme avec perror)
void BFFatal(const char *message);

#ifdef __cplusplus
}
#endif

#endif // BF_COMMON_H
