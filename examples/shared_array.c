#include "BFMemory.h"
#include "BFSharedArray.h"

#include <stdio.h>
#include <string.h>

static void destroy_string(void *pointer) {
    BFMemoryRelease(pointer);
}

int main(void) {
    BFSharedArray *array = BFSharedArrayCreate(destroy_string);
    if (!array) {
        fprintf(stderr, "Failed to create BFSharedArray\n");
        return 1;
    }
    const char *words[] = {"alpha", "beta", "gamma"};
    for (int index = 0; index < 3; ++index) {
        size_t length = strlen(words[index]);
        char  *string = (char *)BFMemoryAllocate(length + 1U);
        memcpy(string, words[index], length + 1U);
        (void)BFSharedArrayPush(array, string);
    }
    // Insert at front
    char *zero = (char *)BFMemoryAllocate(5);
    memcpy(zero, "zero", 5);
    (void)BFSharedArrayUnshift(array, zero);

    // Print
    size_t count = BFSharedArrayCount(array);
    for (size_t index = 0; index < count; ++index) {
        char *string = (char *)BFSharedArrayGet(array, index);
        printf("[%zu] %s\n", index, string ? string : "<null>");
    }

    BFSharedArrayFree(array);
    return 0;
}
