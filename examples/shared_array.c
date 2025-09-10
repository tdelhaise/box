#include "box/BFMemory.h"
#include "box/BFSharedArray.h"

#include <stdio.h>
#include <string.h>

static void destroy_string(void *p) {
    BFMemoryRelease(p);
}

int main(void) {
    BFSharedArray *a = BFSharedArrayCreate(destroy_string);
    if (!a) {
        fprintf(stderr, "Failed to create BFSharedArray\n");
        return 1;
    }
    const char *words[] = {"alpha", "beta", "gamma"};
    for (int i = 0; i < 3; ++i) {
        size_t n = strlen(words[i]);
        char  *s = (char *)BFMemoryAllocate(n + 1U);
        memcpy(s, words[i], n + 1U);
        (void)BFSharedArrayPush(a, s);
    }
    // Insert at front
    char *z = (char *)BFMemoryAllocate(5);
    memcpy(z, "zero", 5);
    (void)BFSharedArrayUnshift(a, z);

    // Print
    size_t count = BFSharedArrayCount(a);
    for (size_t i = 0; i < count; ++i) {
        char *s = (char *)BFSharedArrayGet(a, i);
        printf("[%zu] %s\n", i, s ? s : "<null>");
    }

    BFSharedArrayFree(a);
    return 0;
}
