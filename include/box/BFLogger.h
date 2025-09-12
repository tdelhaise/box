#ifndef BF_LOGGER_H
#define BF_LOGGER_H

#include <stdarg.h>

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
// target: "stderr" (default), other values reserved for future ("syslog", "oslog", "eventlog", "file:/path").
int  BFLoggerSetTarget(const char *target);

void BFLogWrite(BFLogLevel level, const char *fmt, ...);
void BFLogWriteV(BFLogLevel level, const char *fmt, va_list ap);

#ifdef __cplusplus
}
#endif

#endif // BF_LOGGER_H

