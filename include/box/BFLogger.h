#ifndef BF_LOGGER_H
#define BF_LOGGER_H

#include <stdarg.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum BFLogLevel {
    BF_LOG_TRACE = 0,
    BF_LOG_DEBUG = 1,
    BF_LOG_INFO  = 2,
    BF_LOG_WARN  = 3,
    BF_LOG_ERROR = 4,
} BFLogLevel;

void BFLoggerInit(const char *programName);
void BFLoggerSetLevel(BFLogLevel level);
// Targets: "stderr", "syslog" (Unix), "oslog" (macOS), "eventlog" (Windows), "file:/path".
// Defaults (selected in BFLoggerInit):
//   - Windows:   eventlog
//   - macOS:     oslog (falls back to syslog if os/log unavailable)
//   - Unix-like: syslog
//   - Others:    stderr
int BFLoggerSetTarget(const char *target);

void BFLogWrite(BFLogLevel level, const char *fmt, ...);
void BFLogWriteV(BFLogLevel level, const char *fmt, va_list ap);

// Helpers for introspection / diagnostics
BFLogLevel BFLoggerGetLevel(void);
const char *BFLoggerLevelName(BFLogLevel level); // returns lowercase canonical name
// Writes current target name into buffer: stderr|syslog|oslog|eventlog|file:/path
void BFLoggerGetTarget(char *buffer, size_t bufferSize);

#ifdef __cplusplus
}
#endif

#endif // BF_LOGGER_H
