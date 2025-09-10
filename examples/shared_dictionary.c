#include "box/BFMemory.h"
#include "box/BFSharedDictionary.h"

#include <stdio.h>
#include <string.h>

static void free_value(void *p) {
    BFMemoryRelease(p);
}

int main(void) {
    BFSharedDictionary *d = BFSharedDictionaryCreate(free_value);
    if (!d) {
        fprintf(stderr, "Failed to create BFSharedDictionary\n");
        return 1;
    }
    // Insert key/value
    const char *msg = "hello";
    char       *v   = (char *)BFMemoryAllocate(strlen(msg) + 1U);
    memcpy(v, msg, strlen(msg) + 1U);
    (void)BFSharedDictionarySet(d, "greeting", v);

    // Get and print
    char *got = (char *)BFSharedDictionaryGet(d, "greeting");
    printf("greeting = %s\n", got ? got : "<null>");

    BFSharedDictionaryFree(d);
    return 0;
}
