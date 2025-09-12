#include "box/BFMemory.h"
#include "box/BFSharedArray.h"

#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct Item {
    int value;
} Item;

static Item *make_item(int value) {
    Item *item  = (Item *)BFMemoryAllocate(sizeof(Item));
    item->value = value;
    return item;
}

static void destroy_item(void *pointer) {
    BFMemoryRelease(pointer);
}

typedef struct ThreadContext {
    BFSharedArray *array;
    int            base;
    int            count;
} ThreadContext;

static void *worker_push(void *argument) {
    ThreadContext *context = (ThreadContext *)argument;
    for (int index = 0; index < context->count; ++index) {
        (void)BFSharedArrayPush(context->array, make_item(context->base + index));
    }
    return NULL;
}

int main(void) {
    const char *stress      = getenv("BOX_STRESS_ENABLE");
    int         perThread   = (stress && *stress) ? 20000 : 2000; // scale down by default
    int         threadCount = (stress && *stress) ? 8 : 4;

    BFSharedArray *array = BFSharedArrayCreate(destroy_item);
    assert(array != NULL);

    pthread_t     threads[16];
    ThreadContext contexts[16];
    const int     totalExpected = perThread * threadCount;
    for (int index = 0; index < threadCount; ++index) {
        contexts[index].array = array;
        contexts[index].base  = index * perThread;
        contexts[index].count = perThread;
        assert(pthread_create(&threads[index], NULL, worker_push, &contexts[index]) == 0);
    }
    for (int index = 0; index < threadCount; ++index) {
        (void)pthread_join(threads[index], NULL);
    }
    size_t arrayCount = BFSharedArrayCount(array);
    assert((int)arrayCount == totalExpected);
    BFSharedArrayFree(array);
    printf("test_BFSharedArrayStress: OK (count=%zu)\n", arrayCount);
    return 0;
}
