#include "box/BFSharedDictionary.h"
#include "box/BFMemory.h"

#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

typedef struct StrBox {
    char *s;
} StrBox;

static int g_destroyed = 0;

static void destroy_value(void *ptr) {
    if (ptr) {
        StrBox *b = (StrBox *)ptr;
        if (b->s)
            BFMemoryRelease(b->s);
        BFMemoryRelease(b);
        g_destroyed++;
    }
}

static StrBox *make_box(const char *txt) {
    StrBox *b = (StrBox *)BFMemoryAllocate(sizeof(StrBox));
    assert(b != NULL);
    size_t n = strlen(txt);
    b->s     = (char *)BFMemoryAllocate(n + 1U);
    memcpy(b->s, txt, n);
    b->s[n] = '\0';
    return b;
}

static void *thread_insert(void *arg) {
    BFSharedDictionary *d = (BFSharedDictionary *)arg;
    // Insert 100 keys unique to this thread (prefix tX_)
    char key[32];
    for (int i = 0; i < 100; ++i) {
        snprintf(key, sizeof(key), "t%p_%d", (void *)pthread_self(), i);
        (void)BFSharedDictionarySet(d, key, make_box(key));
    }
    return NULL;
}

int main(void) {
    g_destroyed = 0;
    BFSharedDictionary *d = BFSharedDictionaryCreate(destroy_value);
    assert(d != NULL);
    assert(BFSharedDictionaryCount(d) == 0U);

    // Basic set/get/replace/remove
    assert(BFSharedDictionarySet(d, "a", make_box("va")) == 0);
    assert(BFSharedDictionarySet(d, "b", make_box("vb")) == 0);
    assert(BFSharedDictionaryCount(d) == 2U);
    StrBox *ba = (StrBox *)BFSharedDictionaryGet(d, "a");
    assert(ba && strcmp(ba->s, "va") == 0);

    // Replace should destroy old value via destroy_cb
    int before_destroy = g_destroyed;
    assert(BFSharedDictionarySet(d, "a", make_box("va2")) == 0);
    assert(g_destroyed == before_destroy + 1);
    ba = (StrBox *)BFSharedDictionaryGet(d, "a");
    assert(ba && strcmp(ba->s, "va2") == 0);

    // Remove returns value and does not call destroy_cb for it (caller must free)
    StrBox *removed = (StrBox *)BFSharedDictionaryRemove(d, "b");
    assert(removed && strcmp(removed->s, "vb") == 0);
    BFMemoryRelease(removed->s);
    BFMemoryRelease(removed);
    assert(BFSharedDictionaryGet(d, "b") == NULL);

    // Concurrency smoke test: 4 threads insert 100 items each
    pthread_t th[4];
    for (int i = 0; i < 4; ++i) {
        assert(pthread_create(&th[i], NULL, thread_insert, d) == 0);
    }
    for (int i = 0; i < 4; ++i) {
        (void)pthread_join(th[i], NULL);
    }
    // Count should be at least 401 (previous key "a" plus ~400 inserts). Collisions may replace, but keys include thread id so unique.
    assert(BFSharedDictionaryCount(d) >= 401U);

    // Clear destroys all remaining values
    size_t before_clear = BFSharedDictionaryCount(d);
    assert(BFSharedDictionaryClear(d) == 0);
    assert(BFSharedDictionaryCount(d) == 0U);
    assert(g_destroyed >= (int)before_clear);

    BFSharedDictionaryFree(d);
    printf("test_BFSharedDictionary: OK\n");
    return 0;
}

