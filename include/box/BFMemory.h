// Minimal BoxFoundation memory abstraction
// Thread-safe allocate/release for future tracing/instrumentation

#ifndef BF_MEMORY_H
#define BF_MEMORY_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Allocates zero-initialized memory of given size.
// Thread-safe. Returns NULL on failure.
void *BFMemoryAllocate(size_t size);

// Releases memory previously allocated by BFMemoryAllocate (safe on NULL).
// Thread-safe.
void BFMemoryRelease(void *ptr);

// Optional stats to observe memory usage in real time.
typedef struct BFMemoryStats {
    size_t currentBytes;
    size_t peakBytes;
    size_t currentBlocks;
    size_t peakBlocks;
} BFMemoryStats;

// Retrieves current/peak memory usage and block counts. Thread-safe.
void BFMemoryGetStats(BFMemoryStats *outStats);

// Dumps memory statistics to stderr using BoxFoundation logging.
// Safe to call at any time; thread-safe.
void BFMemoryDumpStats(void);

#ifdef __cplusplus
}
#endif

#endif // BF_MEMORY_H
