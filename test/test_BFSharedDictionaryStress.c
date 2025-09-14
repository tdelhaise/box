#include "BFMemory.h"
#include "BFSharedDictionary.h"

#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct StrBox {
    char *string;
} StrBox;

static void destroy_value(void *pointer) {
    if (!pointer)
        return;
    StrBox *box = (StrBox *)pointer;
    if (box->string)
        BFMemoryRelease(box->string);
    BFMemoryRelease(box);
}

static StrBox *make_box(const char *text) {
    size_t  length = strlen(text);
    StrBox *box    = (StrBox *)BFMemoryAllocate(sizeof(StrBox));
    box->string    = (char *)BFMemoryAllocate(length + 1U);
    memcpy(box->string, text, length + 1U);
    return box;
}

typedef struct ThreadContext {
    BFSharedDictionary *dictionary;
    char                prefix;
    int                 count;
} ThreadContext;

static void *worker_set(void *argument) {
    ThreadContext *context = (ThreadContext *)argument;
    char           key[32];
    for (int index = 0; index < context->count; ++index) {
        snprintf(key, sizeof(key), "%c%d", context->prefix, index);
        (void)BFSharedDictionarySet(context->dictionary, key, make_box(key));
    }
    return NULL;
}

int main(void) {
    const char *stress      = getenv("BOX_STRESS_ENABLE");
    int         perThread   = (stress && *stress) ? 20000 : 2000;
    int         threadCount = (stress && *stress) ? 8 : 4;

    BFSharedDictionary *dictionary = BFSharedDictionaryCreate(destroy_value);
    assert(dictionary != NULL);

    pthread_t     threads[16];
    ThreadContext contexts[16];
    for (int index = 0; index < threadCount; ++index) {
        contexts[index].dictionary = dictionary;
        contexts[index].prefix     = (char)('A' + index);
        contexts[index].count      = perThread;
        assert(pthread_create(&threads[index], NULL, worker_set, &contexts[index]) == 0);
    }
    for (int index = 0; index < threadCount; ++index) {
        (void)pthread_join(threads[index], NULL);
    }

    size_t expectedMinimum = (size_t)(perThread * threadCount);
    size_t haveCount       = BFSharedDictionaryCount(dictionary);
    assert(haveCount >= expectedMinimum);

    BFSharedDictionaryFree(dictionary);
    printf("test_BFSharedDictionaryStress: OK (count=%zu)\n", haveCount);
    return 0;
}
