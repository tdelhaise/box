#include "box/BFSharedArray.h"
#include "box/BFMemory.h"

#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct Item { int v; } Item;

static Item *make_item(int v) {
    Item *p = (Item *)BFMemoryAllocate(sizeof(Item));
    p->v    = v;
    return p;
}

static void destroy_item(void *p) {
    BFMemoryRelease(p);
}

typedef struct ThreadCtx {
    BFSharedArray *arr;
    int            base;
    int            count;
} ThreadCtx;

static void *worker_push(void *arg) {
    ThreadCtx *c = (ThreadCtx *)arg;
    for (int i = 0; i < c->count; ++i) {
        (void)BFSharedArrayPush(c->arr, make_item(c->base + i));
    }
    return NULL;
}

int main(void) {
    const char *stress = getenv("BOX_STRESS_ENABLE");
    int         per    = (stress && *stress) ? 20000 : 2000; // scale down by default
    int         thn    = (stress && *stress) ? 8 : 4;

    BFSharedArray *a = BFSharedArrayCreate(destroy_item);
    assert(a != NULL);

    pthread_t  th[16];
    ThreadCtx  ctx[16];
    const int  total_expected = per * thn;
    for (int i = 0; i < thn; ++i) {
        ctx[i].arr   = a;
        ctx[i].base  = i * per;
        ctx[i].count = per;
        assert(pthread_create(&th[i], NULL, worker_push, &ctx[i]) == 0);
    }
    for (int i = 0; i < thn; ++i) {
        (void)pthread_join(th[i], NULL);
    }
    size_t count = BFSharedArrayCount(a);
    assert((int)count == total_expected);
    BFSharedArrayFree(a);
    printf("test_BFSharedArrayStress: OK (count=%zu)\n", count);
    return 0;
}

