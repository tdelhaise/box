#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 199309L
#endif
#include "box/BFMemory.h"
#include "box/BFSharedDictionary.h"

#include <stdio.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>

static void destroy_value(void *p) {
    BFMemoryRelease(p);
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
    BFSharedDictionary *d = BFSharedDictionaryCreate(destroy_value);
    if (!d) {
        fprintf(stderr, "cannot create dict\n");
        return 1;
    }
    const int N = 100000; // 100k
    char      key[32];
    double    t0 = now_sec();
    for (int i = 0; i < N; ++i) {
        int   n = snprintf(key, sizeof(key), "k%d", i);
        char *v = (char *)BFMemoryAllocate((size_t)n + 1U);
        memcpy(v, key, (size_t)n + 1U);
        (void)BFSharedDictionarySet(d, key, v);
    }
    double t1     = now_sec();
    double set_ps = (double)N / (t1 - t0);
    printf("BFSharedDictionary set: %.0f ops/s (N=%d)\n", set_ps, N);

    // Sampled lookups
    volatile int sum = 0;
    for (int i = 0; i < N; i += 97) {
        int n = snprintf(key, sizeof(key), "k%d", i);
        (void)n;
        char *v = (char *)BFSharedDictionaryGet(d, key);
        sum += (v && v[0]) ? 1 : 0;
    }
    printf("BFSharedDictionary sampled gets sum=%d\n", sum);

    BFSharedDictionaryFree(d);
    return 0;
}
