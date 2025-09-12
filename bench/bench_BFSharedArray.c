#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif
#include "box/BFMemory.h"
#include "box/BFSharedArray.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>

static void destroy_string(void *pointer) {
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
    BFSharedArray *array = BFSharedArrayCreate(destroy_string);
    if (!array) {
        fprintf(stderr, "cannot create array\n");
        return 1;
    }
    const int operationCount = 100000; // 100k
    double    startSeconds   = now_sec();
    for (int index = 0; index < operationCount; ++index) {
        char  buffer[32];
        int   written = snprintf(buffer, sizeof(buffer), "v%d", index);
        char *string  = (char *)BFMemoryAllocate((size_t)written + 1U);
        memcpy(string, buffer, (size_t)written + 1U);
        (void)BFSharedArrayPush(array, string);
    }
    double endSeconds = now_sec();
    double pushPerSec = (double)operationCount / (endSeconds - startSeconds);
    printf("BFSharedArray push: %.0f ops/s (N=%d)\n", pushPerSec, operationCount);

    // Random-ish reads (every 101st)
    volatile int sampledSum = 0;
    for (int index = 0; index < operationCount; index += 101) {
        char *string = (char *)BFSharedArrayGet(array, (size_t)index);
        sampledSum += (string && string[0]) ? 1 : 0;
    }
    printf("BFSharedArray sampled reads sum=%d\n", sampledSum);

    BFSharedArrayFree(array);
    return 0;
}
