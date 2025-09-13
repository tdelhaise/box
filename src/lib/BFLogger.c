#include "box/BFLogger.h"

#include <stdio.h>
#include <string.h>
#include <time.h>
#if defined(__APPLE__)
#include <AvailabilityMacros.h>
#if __has_include(<os/log.h>)
#include <os/log.h>
#define BF_HAVE_OSLOG 1
#endif
#endif
#if defined(__unix__) || defined(__APPLE__)
#include <syslog.h>
#endif
#if defined(_WIN32)
#include <windows.h>
#endif

static BFLogLevel g_level = BF_LOG_INFO;
typedef enum BFLogTarget { TARGET_STDERR = 0, TARGET_SYSLOG, TARGET_OSLOG, TARGET_EVENTLOG, TARGET_FILE } BFLogTarget;
static BFLogTarget g_target        = TARGET_STDERR;
static char        g_prog[32]      = {0};
static FILE       *g_file          = NULL;
static char        g_filePath[256] = {0};
#if !defined(__cplusplus)
_Static_assert(sizeof(g_filePath) >= 64, "file path buffer too small for target name");
#endif
#if defined(BF_HAVE_OSLOG)
static os_log_t g_oslog = NULL;
#endif
#if defined(_WIN32)
static HANDLE g_eventSource = NULL;
#endif
static int g_targetExplicit = 0; // whether user explicitly set target

void BFLoggerInit(const char *programName) {
    if (programName && *programName) {
        strncpy(g_prog, programName, sizeof(g_prog) - 1);
        g_prog[sizeof(g_prog) - 1] = '\0';
    }
    // Select platform-specific default target
    if (!g_targetExplicit) {
#if defined(_WIN32)
        (void)BFLoggerSetTarget("eventlog");
#elif defined(__APPLE__)
#if defined(BF_HAVE_OSLOG)
        (void)BFLoggerSetTarget("oslog");
#else
        (void)BFLoggerSetTarget("syslog");
#endif
#elif defined(__unix__)
        (void)BFLoggerSetTarget("syslog");
#else
        (void)BFLoggerSetTarget("stderr");
#endif
        // Do not mark default as explicit selection
        g_targetExplicit = 0;
    }
}

void BFLoggerSetLevel(BFLogLevel level) {
    g_level = level;
}

int BFLoggerSetTarget(const char *target) {
    if (!target) {
        g_target         = TARGET_STDERR;
        g_targetExplicit = 1;
        return 0;
    }
    if (strncmp(target, "stderr", 6) == 0) {
        g_target         = TARGET_STDERR;
        g_targetExplicit = 1;
        return 0;
    }
#if defined(__unix__) || defined(__APPLE__)
    if (strncmp(target, "syslog", 6) == 0) {
        g_target = TARGET_SYSLOG;
        openlog(g_prog[0] ? g_prog : "box", LOG_PID | LOG_NDELAY, LOG_USER);
        g_targetExplicit = 1;
        return 0;
    }
#endif
#if defined(BF_HAVE_OSLOG)
    if (strncmp(target, "oslog", 5) == 0 || strncmp(target, "os_log", 6) == 0) {
        g_target = TARGET_OSLOG;
        if (!g_oslog) {
            const char *subsystem = g_prog[0] ? g_prog : "box";
            g_oslog               = os_log_create(subsystem, "general");
            if (!g_oslog) {
                g_oslog = OS_LOG_DEFAULT;
            }
        }
        g_targetExplicit = 1;
        return 0;
    }
#endif
#if defined(_WIN32)
    if (strncmp(target, "eventlog", 8) == 0 || strncmp(target, "event-log", 9) == 0) {
        g_target = TARGET_EVENTLOG;
        if (g_eventSource) {
            DeregisterEventSource(g_eventSource);
            g_eventSource = NULL;
        }
        const char *sourceName = g_prog[0] ? g_prog : "box";
        g_eventSource          = RegisterEventSourceA(NULL, sourceName);
        g_targetExplicit       = 1;
        return 0;
    }
#endif
    if (strncmp(target, "file:", 5) == 0) {
        const char *path = target + 5;
        if (g_file) {
            fclose(g_file);
            g_file = NULL;
        }
        strncpy(g_filePath, path, sizeof(g_filePath) - 1);
        g_filePath[sizeof(g_filePath) - 1] = '\0';
        g_file                             = fopen(g_filePath, "a");
        if (!g_file) {
            g_target         = TARGET_STDERR;
            g_targetExplicit = 1;
            return -1;
        }
        g_target         = TARGET_FILE;
        g_targetExplicit = 1;
        return 0;
    }
    g_target         = TARGET_STDERR;
    g_targetExplicit = 1;
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
        time_t    now = time(NULL);
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
#if defined(__unix__) || defined(__APPLE__)
    else if (g_target == TARGET_SYSLOG) {
        int pri = LOG_INFO;
        switch (level) {
        case BF_LOG_TRACE:
        case BF_LOG_DEBUG:
            pri = LOG_DEBUG;
            break;
        case BF_LOG_INFO:
            pri = LOG_INFO;
            break;
        case BF_LOG_WARN:
            pri = LOG_WARNING;
            break;
        case BF_LOG_ERROR:
            pri = LOG_ERR;
            break;
        }
        char buffer[512];
        vsnprintf(buffer, sizeof(buffer), fmt, ap);
        syslog(pri, "%s", buffer);
    }
#endif
#if defined(BF_HAVE_OSLOG)
    else if (g_target == TARGET_OSLOG) {
        os_log_type_t t = OS_LOG_TYPE_DEFAULT;
        switch (level) {
        case BF_LOG_TRACE:
        case BF_LOG_DEBUG:
            t = OS_LOG_TYPE_DEBUG;
            break;
        case BF_LOG_INFO:
            t = OS_LOG_TYPE_DEFAULT;
            break;
        case BF_LOG_WARN:
            t = OS_LOG_TYPE_INFO;
            break;
        case BF_LOG_ERROR:
            t = OS_LOG_TYPE_ERROR;
            break;
        }
        char buffer[512];
        vsnprintf(buffer, sizeof(buffer), fmt, ap);
        os_log_with_type(g_oslog ? g_oslog : OS_LOG_DEFAULT, t, "%{public}s", buffer);
    }
#endif
#if defined(_WIN32)
    else if (g_target == TARGET_EVENTLOG) {
        WORD eventType = EVENTLOG_INFORMATION_TYPE;
        switch (level) {
        case BF_LOG_TRACE:
        case BF_LOG_DEBUG:
        case BF_LOG_INFO:
            eventType = EVENTLOG_INFORMATION_TYPE;
            break;
        case BF_LOG_WARN:
            eventType = EVENTLOG_WARNING_TYPE;
            break;
        case BF_LOG_ERROR:
            eventType = EVENTLOG_ERROR_TYPE;
            break;
        }
        char   buffer[512];
        LPCSTR strings[1];
        WORD   stringCount = 0;
        DWORD  eventId     = 0x1000; /* generic */
        vsnprintf(buffer, sizeof(buffer), fmt, ap);
        strings[0]    = buffer;
        stringCount   = 1;
        HANDLE source = g_eventSource;
        if (!source) {
            const char *sourceName = g_prog[0] ? g_prog : "box";
            source                 = RegisterEventSourceA(NULL, sourceName);
        }
        if (source) {
            ReportEventA(source, eventType, 0 /*category*/, eventId, NULL /*userSid*/, stringCount, 0 /*dataSize*/, strings, NULL /*rawData*/);
            if (source != g_eventSource) {
                DeregisterEventSource(source);
            }
        }
    }
#endif
    else if (g_target == TARGET_FILE) {
        if (g_file) {
            time_t    now = time(NULL);
            struct tm tmv;
#if defined(_WIN32)
            tmv = *localtime(&now);
#else
            localtime_r(&now, &tmv);
#endif
            char ts[32];
            strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &tmv);
            fprintf(g_file, "%s [%s] %s: ", ts, lvl(level), g_prog[0] ? g_prog : "box");
            vfprintf(g_file, fmt, ap);
            fputc('\n', g_file);
            fflush(g_file);
        }
    }
}

void BFLogWrite(BFLogLevel level, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    BFLogWriteV(level, fmt, ap);
    va_end(ap);
}

// --- Introspection helpers ---
BFLogLevel BFLoggerGetLevel(void) {
    return g_level;
}

const char *BFLoggerLevelName(BFLogLevel level) {
    switch (level) {
    case BF_LOG_TRACE:
        return "trace";
    case BF_LOG_DEBUG:
        return "debug";
    case BF_LOG_INFO:
        return "info";
    case BF_LOG_WARN:
        return "warn";
    case BF_LOG_ERROR:
        return "error";
    }
    return "info";
}

void BFLoggerGetTarget(char *buffer, size_t bufferSize) {
    if (!buffer || bufferSize == 0)
        return;
    const char *name = "stderr";
    switch (g_target) {
    case TARGET_STDERR:
        name = "stderr";
        break;
    case TARGET_SYSLOG:
        name = "syslog";
        break;
    case TARGET_OSLOG:
        name = "oslog";
        break;
    case TARGET_EVENTLOG:
        name = "eventlog";
        break;
    case TARGET_FILE:
        // Special handling to include path
        if (g_filePath[0] != '\0') {
            snprintf(buffer, bufferSize, "file:%s", g_filePath);
            return;
        }
        name = "file";
        break;
    }
    snprintf(buffer, bufferSize, "%s", name);
}
