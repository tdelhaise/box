#ifndef BF_CONFIG_H
#define BF_CONFIG_H

#include "BFLogger.h"
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BFServerConfig {
    int        hasPort;
    uint16_t   port;
    int        hasLogLevel;
    BFLogLevel logLevel;
    int        hasLogTarget;
    char       logTarget[128];
    int        hasProtocol;
    char       protocol[16]; // "simple"|"v1"
    // Transport toggles (smoke and per-operation)
    int  hasTransportGeneral;
    char transportGeneral[16]; // "clear"|"noise"
    int  hasTransportPut;
    char transportPut[16]; // "clear"|"noise"
    int  hasTransportGet;
    char transportGet[16]; // "clear"|"noise"
    int  hasTransportStatus;
    char transportStatus[16]; // "clear"|"noise"
    // Noise scaffolding config
    int  hasNoisePattern;
    char noisePattern[8]; // "nk"|"ik"
    int  hasPreShareKeyAscii;
    char preShareKeyAscii[128];
} BFServerConfig;

// Loads a minimal TOML-like config for boxd from the given file path.
// Recognized keys:
//   port = 12567
//   log_level = "trace|debug|info|warn|error"
//   log_target = "stderr|syslog|oslog|eventlog|file:/path"
//   transport = "clear|noise"
//   transport_put = "clear|noise"
//   transport_get = "clear|noise"
//   transport_status = "clear|noise"
//   pre_share_key = "ascii-secret"  # dev only, for smoke path
//   noise_pattern = "nk|ik"
// Comments starting with '#' are ignored. Whitespace is ignored.
// Returns 0 on success (even if only some keys present), -1 on error (file not found or parse
// error).
int BFConfigLoadServer(const char *filePath, BFServerConfig *outConfig);

#ifdef __cplusplus
}
#endif

#endif // BF_CONFIG_H
