#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif
#include "box/BFMemory.h"
#include "box/BFSharedDictionary.h"

#include <stdio.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>

static void destroy_value(void *pointer) {
    BFMemoryRelease(pointer);
}

static double now_sec(void) {
#ifdef CLOCK_MONOTONIC
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) == 0) {
        return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
    }
#endif
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + (double)tv.tv_usec / 1e6;
}

int main(void) {
    BFSharedDictionary *dictionary = BFSharedDictionaryCreate(destroy_value);
    if (!dictionary) {
        fprintf(stderr, "cannot create dict\n");
        return 1;
    }
    const int operationCount = 100000; // 100k
    char      key[32];
    double    startSeconds = now_sec();
    for (int index = 0; index < operationCount; ++index) {
        int   written = snprintf(key, sizeof(key), "k%d", index);
        char *value   = (char *)BFMemoryAllocate((size_t)written + 1U);
        memcpy(value, key, (size_t)written + 1U);
        (void)BFSharedDictionarySet(dictionary, key, value);
    }
    double endSeconds    = now_sec();
    double setsPerSecond = (double)operationCount / (endSeconds - startSeconds);
    printf("BFSharedDictionary set: %.0f ops/s (N=%d)\n", setsPerSecond, operationCount);

    // Sampled lookups
    volatile int sampledSum = 0;
    for (int index = 0; index < operationCount; index += 97) {
        int written = snprintf(key, sizeof(key), "k%d", index);
        (void)written;
        char *value = (char *)BFSharedDictionaryGet(dictionary, key);
        sampledSum += (value && value[0]) ? 1 : 0;
    }
    printf("BFSharedDictionary sampled gets sum=%d\n", sampledSum);

    BFSharedDictionaryFree(dictionary);
    return 0;
}
