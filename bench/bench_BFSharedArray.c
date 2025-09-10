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

static void destroy_string(void *p) {
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
    BFSharedArray *a = BFSharedArrayCreate(destroy_string);
    if (!a) {
        fprintf(stderr, "cannot create array\n");
        return 1;
    }
    const int N  = 100000; // 100k
    double    t0 = now_sec();
    for (int i = 0; i < N; ++i) {
        char  buf[32];
        int   n = snprintf(buf, sizeof(buf), "v%d", i);
        char *s = (char *)BFMemoryAllocate((size_t)n + 1U);
        memcpy(s, buf, (size_t)n + 1U);
        (void)BFSharedArrayPush(a, s);
    }
    double t1      = now_sec();
    double push_ps = (double)N / (t1 - t0);
    printf("BFSharedArray push: %.0f ops/s (N=%d)\n", push_ps, N);

    // Random-ish reads (every 101st)
    volatile int sum = 0;
    for (int i = 0; i < N; i += 101) {
        char *s = (char *)BFSharedArrayGet(a, (size_t)i);
        sum += (s && s[0]) ? 1 : 0;
    }
    printf("BFSharedArray sampled reads sum=%d\n", sum);

    BFSharedArrayFree(a);
    return 0;
}
