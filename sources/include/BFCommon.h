#ifndef BF_COMMON_H
#define BF_COMMON_H

#include "BFLogger.h"
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#ifdef __cplusplus
extern "C" {
#endif

// -----------------------------------------------------------------------------
// Constantes globales
// -----------------------------------------------------------------------------
static const uint16_t    BFGlobalDefaultPort    = 12567;
static const char *const BFGlobalDefaultAddress = "127.0.0.1";
#define BF_MACRO_MAX_DATAGRAM_SIZE 1200
static const size_t BFGlobalMaxDatagram = BF_MACRO_MAX_DATAGRAM_SIZE; // taille max d'un datagramme UDP

// -----------------------------------------------------------------------------
// Codes d'erreur génériques
// -----------------------------------------------------------------------------
enum { BF_OK = 0, BF_ERR = -1 };

// -----------------------------------------------------------------------------
// Logging / helpers
// -----------------------------------------------------------------------------

// Macro simple de log
#define BFLog(fmt, ...) BFLogWrite(BF_LOG_INFO, fmt, ##__VA_ARGS__)
#define BFError(fmt, ...) BFLogWrite(BF_LOG_ERROR, fmt, ##__VA_ARGS__)
#define BFWarn(fmt, ...) BFLogWrite(BF_LOG_WARN, fmt, ##__VA_ARGS__)
#define BFDebug(fmt, ...) BFLogWrite(BF_LOG_DEBUG, fmt, ##__VA_ARGS__)

// Helper d'erreur fatale (arrête le programme avec perror)
void BFFatal(const char *message);

#ifdef __cplusplus
}
#endif

#endif // BF_COMMON_H
