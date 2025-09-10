#include "box/BFMemory.h"
#include "box/BFSharedDictionary.h"

#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct StrBox {
    char *s;
} StrBox;

static void destroy_value(void *p) {
    if (!p)
        return;
    StrBox *b = (StrBox *)p;
    if (b->s)
        BFMemoryRelease(b->s);
    BFMemoryRelease(b);
}

static StrBox *make_box(const char *txt) {
    size_t  n = strlen(txt);
    StrBox *b = (StrBox *)BFMemoryAllocate(sizeof(StrBox));
    b->s      = (char *)BFMemoryAllocate(n + 1U);
    memcpy(b->s, txt, n + 1U);
    return b;
}

typedef struct ThreadCtx {
    BFSharedDictionary *dict;
    char                prefix;
    int                 count;
} ThreadCtx;

static void *worker_set(void *arg) {
    ThreadCtx *c = (ThreadCtx *)arg;
    char       key[32];
    for (int i = 0; i < c->count; ++i) {
        snprintf(key, sizeof(key), "%c%d", c->prefix, i);
        (void)BFSharedDictionarySet(c->dict, key, make_box(key));
    }
    return NULL;
}

int main(void) {
    const char *stress = getenv("BOX_STRESS_ENABLE");
    int         per    = (stress && *stress) ? 20000 : 2000;
    int         thn    = (stress && *stress) ? 8 : 4;

    BFSharedDictionary *d = BFSharedDictionaryCreate(destroy_value);
    assert(d != NULL);

    pthread_t th[16];
    ThreadCtx ctx[16];
    for (int i = 0; i < thn; ++i) {
        ctx[i].dict   = d;
        ctx[i].prefix = (char)('A' + i);
        ctx[i].count  = per;
        assert(pthread_create(&th[i], NULL, worker_set, &ctx[i]) == 0);
    }
    for (int i = 0; i < thn; ++i) {
        (void)pthread_join(th[i], NULL);
    }

    size_t expected_min = (size_t)(per * thn);
    size_t have         = BFSharedDictionaryCount(d);
    assert(have >= expected_min);

    BFSharedDictionaryFree(d);
    printf("test_BFSharedDictionaryStress: OK (count=%zu)\n", have);
    return 0;
}
