#include "box/BFLogger.h"

#include <stdio.h>
#include <string.h>
#include <time.h>

static BFLogLevel g_level = BF_LOG_INFO;
static enum { TARGET_STDERR = 0 } g_target = TARGET_STDERR;
static char g_prog[32] = {0};

void BFLoggerInit(const char *programName) {
    if (programName && *programName) {
        strncpy(g_prog, programName, sizeof(g_prog) - 1);
        g_prog[sizeof(g_prog) - 1] = '\0';
    }
}

void BFLoggerSetLevel(BFLogLevel level) { g_level = level; }

int BFLoggerSetTarget(const char *target) {
    (void)target; // only stderr for now
    g_target = TARGET_STDERR;
    return 0;
}

static const char *lvl(BFLogLevel l) {
    switch (l) {
    case BF_LOG_TRACE:
        return "TRACE";
    case BF_LOG_DEBUG:
        return "DEBUG";
    case BF_LOG_INFO:
        return "INFO";
    case BF_LOG_WARN:
        return "WARN";
    case BF_LOG_ERROR:
        return "ERROR";
    }
    return "LOG";
}

void BFLogWriteV(BFLogLevel level, const char *fmt, va_list ap) {
    if (level < g_level)
        return;
    if (g_target == TARGET_STDERR) {
        // timestamp
        time_t now = time(NULL);
        struct tm tmv;
#if defined(_WIN32)
        tmv = *localtime(&now);
#else
        localtime_r(&now, &tmv);
#endif
        char ts[32];
        strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &tmv);
        if (g_prog[0])
            fprintf(stderr, "%s [%s] %s: ", ts, lvl(level), g_prog);
        else
            fprintf(stderr, "%s [%s] ", ts, lvl(level));
        vfprintf(stderr, fmt, ap);
        fputc('\n', stderr);
    }
}

void BFLogWrite(BFLogLevel level, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    BFLogWriteV(level, fmt, ap);
    va_end(ap);
}

