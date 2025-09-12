#include "box/BFMemory.h"
#include "box/BFSharedDictionary.h"

#include <stdio.h>
#include <string.h>

static void free_value(void *pointer) {
    BFMemoryRelease(pointer);
}

int main(void) {
    BFSharedDictionary *dictionary = BFSharedDictionaryCreate(free_value);
    if (!dictionary) {
        fprintf(stderr, "Failed to create BFSharedDictionary\n");
        return 1;
    }
    // Insert key/value
    const char *message = "hello";
    char       *value   = (char *)BFMemoryAllocate(strlen(message) + 1U);
    memcpy(value, message, strlen(message) + 1U);
    (void)BFSharedDictionarySet(dictionary, "greeting", value);

    // Get and print
    char *fetched = (char *)BFSharedDictionaryGet(dictionary, "greeting");
    printf("greeting = %s\n", fetched ? fetched : "<null>");

    BFSharedDictionaryFree(dictionary);
    return 0;
}
