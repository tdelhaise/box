#include "box/BFMemory.h"
#include "box/BFSharedDictionary.h"

#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

typedef struct StrBox {
    char *string;
} StrBox;

static int g_destroyed = 0;

static void destroy_value(void *pointer) {
    if (pointer) {
        StrBox *box = (StrBox *)pointer;
        if (box->string)
            BFMemoryRelease(box->string);
        BFMemoryRelease(box);
        g_destroyed++;
    }
}

static StrBox *make_box(const char *text) {
    StrBox *box = (StrBox *)BFMemoryAllocate(sizeof(StrBox));
    assert(box != NULL);
    size_t length = strlen(text);
    box->string   = (char *)BFMemoryAllocate(length + 1U);
    memcpy(box->string, text, length);
    box->string[length] = '\0';
    return box;
}

static void *thread_insert(void *argument) {
    BFSharedDictionary *dictionary = (BFSharedDictionary *)argument;
    // Insert 100 keys unique to this thread (prefix tX_)
    char key[32];
    for (int index = 0; index < 100; ++index) {
        snprintf(key, sizeof(key), "t%p_%d", (void *)pthread_self(), index);
        (void)BFSharedDictionarySet(dictionary, key, make_box(key));
    }
    return NULL;
}

int main(void) {
    g_destroyed                    = 0;
    BFSharedDictionary *dictionary = BFSharedDictionaryCreate(destroy_value);
    assert(dictionary != NULL);
    assert(BFSharedDictionaryCount(dictionary) == 0U);

    // Basic set/get/replace/remove
    assert(BFSharedDictionarySet(dictionary, "a", make_box("va")) == 0);
    assert(BFSharedDictionarySet(dictionary, "b", make_box("vb")) == 0);
    assert(BFSharedDictionaryCount(dictionary) == 2U);
    StrBox *boxA = (StrBox *)BFSharedDictionaryGet(dictionary, "a");
    assert(boxA && strcmp(boxA->string, "va") == 0);

    // Replace should destroy old value via destroy_cb
    int before_destroy = g_destroyed;
    assert(BFSharedDictionarySet(dictionary, "a", make_box("va2")) == 0);
    assert(g_destroyed == before_destroy + 1);
    boxA = (StrBox *)BFSharedDictionaryGet(dictionary, "a");
    assert(boxA && strcmp(boxA->string, "va2") == 0);

    // Remove returns value and does not call destroy_cb for it (caller must free)
    StrBox *removed = (StrBox *)BFSharedDictionaryRemove(dictionary, "b");
    assert(removed && strcmp(removed->string, "vb") == 0);
    BFMemoryRelease(removed->string);
    BFMemoryRelease(removed);
    assert(BFSharedDictionaryGet(dictionary, "b") == NULL);

    // Concurrency smoke test: 4 threads insert 100 items each
    pthread_t threads[4];
    for (int index = 0; index < 4; ++index) {
        assert(pthread_create(&threads[index], NULL, thread_insert, dictionary) == 0);
    }
    for (int index = 0; index < 4; ++index) {
        (void)pthread_join(threads[index], NULL);
    }
    // Count should be at least 401 (previous key "a" plus ~400 inserts). Collisions may replace,
    // but keys include thread id so unique.
    assert(BFSharedDictionaryCount(dictionary) >= 401U);

    // Clear destroys all remaining values
    size_t before_clear = BFSharedDictionaryCount(dictionary);
    assert(BFSharedDictionaryClear(dictionary) == 0);
    assert(BFSharedDictionaryCount(dictionary) == 0U);
    assert(g_destroyed >= (int)before_clear);

    BFSharedDictionaryFree(dictionary);
    printf("test_BFSharedDictionary: OK\n");
    return 0;
}
