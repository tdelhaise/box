#include "BFConfig.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int parse_log_level(const char *value, BFLogLevel *out) {
    if (strcmp(value, "trace") == 0) {
        *out = BF_LOG_TRACE;
        return 0;
    }
    if (strcmp(value, "debug") == 0) {
        *out = BF_LOG_DEBUG;
        return 0;
    }
    if (strcmp(value, "info") == 0) {
        *out = BF_LOG_INFO;
        return 0;
    }
    if (strcmp(value, "warn") == 0) {
        *out = BF_LOG_WARN;
        return 0;
    }
    if (strcmp(value, "error") == 0) {
        *out = BF_LOG_ERROR;
        return 0;
    }
    return -1;
}

static char *trim(char *s) {
    while (*s && isspace((unsigned char)*s))
        ++s;
    if (!*s)
        return s;
    char *end = s + strlen(s) - 1;
    while (end > s && isspace((unsigned char)*end))
        *end-- = '\0';
    return s;
}

int BFConfigLoadServer(const char *filePath, BFServerConfig *outConfig) {
    if (!filePath || !outConfig)
        return -1;
    FILE *f = fopen(filePath, "r");
    if (!f)
        return -1;
    memset(outConfig, 0, sizeof(*outConfig));
    char   line[512];
    size_t lineNumber = 0;
    while (fgets(line, (int)sizeof(line), f) != NULL) {
        lineNumber++;
        char *p = trim(line);
        if (*p == '\0' || *p == '#')
            continue;
        // Expect key = value
        char *eq = strchr(p, '=');
        if (!eq)
            continue; // ignore malformed
        *eq       = '\0';
        char *key = trim(p);
        char *val = trim(eq + 1);
        // Strip quotes for string values
        if (*val == '"') {
            ++val;
            char *quoteEnd = strrchr(val, '"');
            if (quoteEnd)
                *quoteEnd = '\0';
        }
        if (strcmp(key, "port") == 0) {
            long portValue = strtol(val, NULL, 10);
            if (portValue > 0 && portValue < 65536) {
                outConfig->port    = (uint16_t)portValue;
                outConfig->hasPort = 1;
            }
            continue;
        }
        if (strcmp(key, "log_level") == 0) {
            BFLogLevel level;
            if (parse_log_level(val, &level) == 0) {
                outConfig->logLevel    = level;
                outConfig->hasLogLevel = 1;
            }
            continue;
        }
        if (strcmp(key, "log_target") == 0) {
            strncpy(outConfig->logTarget, val, sizeof(outConfig->logTarget) - 1);
            outConfig->logTarget[sizeof(outConfig->logTarget) - 1] = '\0';
            outConfig->hasLogTarget                                = 1;
            continue;
        }
        if (strcmp(key, "transport") == 0) {
            strncpy(outConfig->transportGeneral, val, sizeof(outConfig->transportGeneral) - 1);
            outConfig->transportGeneral[sizeof(outConfig->transportGeneral) - 1] = '\0';
            outConfig->hasTransportGeneral                                       = 1;
            continue;
        }
        if (strcmp(key, "transport_put") == 0) {
            strncpy(outConfig->transportPut, val, sizeof(outConfig->transportPut) - 1);
            outConfig->transportPut[sizeof(outConfig->transportPut) - 1] = '\0';
            outConfig->hasTransportPut                                   = 1;
            continue;
        }
        if (strcmp(key, "transport_get") == 0) {
            strncpy(outConfig->transportGet, val, sizeof(outConfig->transportGet) - 1);
            outConfig->transportGet[sizeof(outConfig->transportGet) - 1] = '\0';
            outConfig->hasTransportGet                                   = 1;
            continue;
        }
        if (strcmp(key, "transport_status") == 0) {
            strncpy(outConfig->transportStatus, val, sizeof(outConfig->transportStatus) - 1);
            outConfig->transportStatus[sizeof(outConfig->transportStatus) - 1] = '\0';
            outConfig->hasTransportStatus                                      = 1;
            continue;
        }
        if (strcmp(key, "pre_share_key") == 0) {
            strncpy(outConfig->preShareKeyAscii, val, sizeof(outConfig->preShareKeyAscii) - 1);
            outConfig->preShareKeyAscii[sizeof(outConfig->preShareKeyAscii) - 1] = '\0';
            outConfig->hasPreShareKeyAscii                                       = 1;
            continue;
        }
        if (strcmp(key, "noise_pattern") == 0) {
            strncpy(outConfig->noisePattern, val, sizeof(outConfig->noisePattern) - 1);
            outConfig->noisePattern[sizeof(outConfig->noisePattern) - 1] = '\0';
            outConfig->hasNoisePattern                                   = 1;
            continue;
        }
        // ignore unknown keys for now
    }
    // Keep lineNumber for potential future diagnostics while avoiding unused warnings in
    // stricter toolchains.
    (void)lineNumber;
    fclose(f);
    return 0;
}
