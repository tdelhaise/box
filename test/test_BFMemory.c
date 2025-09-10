#include "box/BFMemory.h"

#include <assert.h>
#include <stdio.h>

static void get_stats(BFMemoryStats *out) {
    BFMemoryGetStats(out);
}

int main(void) {
    BFMemoryStats before = {0};
    get_stats(&before);

    // Allocate 100 bytes and verify counters increase accordingly.
    void *p = BFMemoryAllocate(100);
    assert(p != NULL);

    BFMemoryStats afterAlloc = {0};
    get_stats(&afterAlloc);

    assert(afterAlloc.currentBlocks == before.currentBlocks + 1);
    assert(afterAlloc.currentBytes == before.currentBytes + 100);

    // Free and verify counters return to baseline.
    BFMemoryRelease(p);

    BFMemoryStats afterFree = {0};
    get_stats(&afterFree);

    assert(afterFree.currentBlocks == before.currentBlocks);
    assert(afterFree.currentBytes == before.currentBytes);

    // Zero-size allocation should count as 1 byte and 1 block.
    void *z = BFMemoryAllocate(0);
    assert(z != NULL);
    BFMemoryStats zeroAlloc = {0};
    get_stats(&zeroAlloc);
    assert(zeroAlloc.currentBlocks == afterFree.currentBlocks + 1);
    assert(zeroAlloc.currentBytes == afterFree.currentBytes + 1);
    BFMemoryRelease(z);

    BFMemoryStats finalStats = {0};
    get_stats(&finalStats);
    assert(finalStats.currentBlocks == afterFree.currentBlocks);
    assert(finalStats.currentBytes == afterFree.currentBytes);

    printf("test_BFMemory: OK\n");
    return 0;
}

