#include "box/BFMemory.h"

// Use pthread mutex for thread-safety on POSIX systems
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>

#include "box/BFCommon.h"

static pthread_mutex_t staticGlobalMemoryLock    = PTHREAD_MUTEX_INITIALIZER;
static size_t          staticGlobalCurrentBytes  = 0;
static size_t          staticGlobalPeakBytes     = 0;
static size_t          staticGlobalCurrentBlocks = 0;
static size_t          staticGlobalPeakBlocks    = 0;
static int             staticGlobalTraceEnabled  = 0;
static int             staticGlobalInitDone      = 0;

// Simple header to track allocation size for stats
typedef struct BFMemoryHeader {
    size_t allocationSize;
} BFMemoryHeader;

static void BFMemoryDumpAtExit(void) {
    BFMemoryDumpStats();
}

static void BFMemoryMaybeInit(void) {
    if (staticGlobalInitDone != 0) {
        return;
    }
    staticGlobalInitDone = 1;
    const char *trace    = getenv("BF_MEMORY_TRACE");
    if (trace != NULL && trace[0] != '\0' && trace[0] != '0') {
        staticGlobalTraceEnabled = 1;
        atexit(BFMemoryDumpAtExit);
        // Register a signal handler to dump stats on SIGUSR1 (debug aid only).
#if defined(BOX_MEMORY_SIGNAL_TRACE) && defined(SIGUSR1)
        signal(SIGUSR1, SIG_IGN);
        signal(SIGUSR1, (void (*)(int))BFMemoryDumpStats);
#endif
    }
}

void *BFMemoryAllocate(size_t size) {
    if (size == 0) {
        size = 1; // ensure non-zero allocation
    }

    pthread_mutex_lock(&staticGlobalMemoryLock);
    BFMemoryMaybeInit();

    BFMemoryHeader *header = (BFMemoryHeader *)calloc(1, sizeof(BFMemoryHeader) + size);
    if (header == NULL) {
        pthread_mutex_unlock(&staticGlobalMemoryLock);
        return NULL;
    }

    header->allocationSize = size;
    staticGlobalCurrentBytes += size;
    staticGlobalCurrentBlocks += 1;
    if (staticGlobalCurrentBytes > staticGlobalPeakBytes) {
        staticGlobalPeakBytes = staticGlobalCurrentBytes;
    }
    if (staticGlobalCurrentBlocks > staticGlobalPeakBlocks) {
        staticGlobalPeakBlocks = staticGlobalCurrentBlocks;
    }

    void *userPointer = (void *)(header + 1);
    pthread_mutex_unlock(&staticGlobalMemoryLock);
    return userPointer;
}

void BFMemoryRelease(void *pointer) {
    if (pointer == NULL) {
        return;
    }

    pthread_mutex_lock(&staticGlobalMemoryLock);
    BFMemoryHeader *header         = ((BFMemoryHeader *)pointer) - 1;
    size_t          allocationSize = header->allocationSize;

    if (staticGlobalCurrentBytes >= allocationSize) {
        staticGlobalCurrentBytes -= allocationSize;
    }
    if (staticGlobalCurrentBlocks > 0) {
        staticGlobalCurrentBlocks -= 1;
    }

    free(header);
    pthread_mutex_unlock(&staticGlobalMemoryLock);
}

void BFMemoryGetStats(BFMemoryStats *outStats) {
    if (outStats == NULL) {
        return;
    }

    pthread_mutex_lock(&staticGlobalMemoryLock);
    outStats->currentBytes  = staticGlobalCurrentBytes;
    outStats->peakBytes     = staticGlobalPeakBytes;
    outStats->currentBlocks = staticGlobalCurrentBlocks;
    outStats->peakBlocks    = staticGlobalPeakBlocks;
    pthread_mutex_unlock(&staticGlobalMemoryLock);
}

void BFMemoryDumpStats(void) {
    BFMemoryStats stats = {0};
    BFMemoryGetStats(&stats);
    BFLog("BFMemory: currentBytes=%zu peakBytes=%zu currentBlocks=%zu peakBlocks=%zu", stats.currentBytes, stats.peakBytes, stats.currentBlocks, stats.peakBlocks);
}
