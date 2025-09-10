#include "box/BFMemory.h"

// Use pthread mutex for thread-safety on POSIX systems
#include <pthread.h>
#include <stdlib.h>

static pthread_mutex_t g_bfmem_lock = PTHREAD_MUTEX_INITIALIZER;

void *BFMemoryAllocate(size_t size) {
    void *p = NULL;
    pthread_mutex_lock(&g_bfmem_lock);
    // Zero-initialize for safety and parity with prior calloc usage
    p = calloc(1, size);
    pthread_mutex_unlock(&g_bfmem_lock);
    return p;
}

void BFMemoryRelease(void *ptr) {
    if (!ptr) return;
    pthread_mutex_lock(&g_bfmem_lock);
    free(ptr);
    pthread_mutex_unlock(&g_bfmem_lock);
}

