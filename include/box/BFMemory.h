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

#ifdef __cplusplus
}
#endif

#endif // BF_MEMORY_H

