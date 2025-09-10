#include "box/BFSharedArray.h"

#include "box/BFCommon.h"
#include "box/BFMemory.h"

#include <limits.h>
#include <pthread.h>
#include <string.h>

typedef struct BFSharedArrayNode {
    void                     *value;
    struct BFSharedArrayNode *prev;
    struct BFSharedArrayNode *next;
} BFSharedArrayNode;

struct BFSharedArray {
    pthread_mutex_t      mutex;
    BFSharedArrayNode   *head;
    BFSharedArrayNode   *tail;
    size_t               count;
    BFSharedArrayDestroy destroy_cb; // optional
};

static BFSharedArrayNode *node_new(void *value) {
    BFSharedArrayNode *n = (BFSharedArrayNode *)BFMemoryAllocate(sizeof(*n));
    if (!n)
        return NULL;
    n->value = value;
    n->prev  = NULL;
    n->next  = NULL;
    return n;
}

static void node_free(BFSharedArrayNode *n) {
    BFMemoryRelease(n);
}

static BFSharedArrayNode *get_node_at_locked(BFSharedArray *a, size_t index) {
    if (index >= a->count)
        return NULL;
    // bidirectional walk for efficiency
    if (index < a->count / 2U) {
        BFSharedArrayNode *p = a->head;
        for (size_t i = 0; p && i < index; ++i)
            p = p->next;
        return p;
    } else {
        BFSharedArrayNode *p = a->tail;
        for (size_t i = a->count - 1U; p && i > index; --i)
            p = p->prev;
        return p;
    }
}

BFSharedArray *BFSharedArrayCreate(BFSharedArrayDestroy destroy_cb) {
    BFSharedArray *a = (BFSharedArray *)BFMemoryAllocate(sizeof(*a));
    if (!a)
        return NULL;
    memset(a, 0, sizeof(*a));
    (void)pthread_mutex_init(&a->mutex, NULL);
    a->destroy_cb = destroy_cb;
    return a;
}

void BFSharedArrayFree(BFSharedArray *array) {
    if (!array)
        return;
    (void)BFSharedArrayClear(array);
    pthread_mutex_destroy(&array->mutex);
    BFMemoryRelease(array);
}

size_t BFSharedArrayCount(BFSharedArray *array) {
    if (!array)
        return 0;
    pthread_mutex_lock(&array->mutex);
    size_t n = array->count;
    pthread_mutex_unlock(&array->mutex);
    return n;
}

static int size_to_index(size_t idx) {
    if (idx > (size_t)INT_MAX)
        return BF_ERR;
    return (int)idx;
}

int BFSharedArrayInsert(BFSharedArray *array, size_t index, void *object) {
    if (!array)
        return BF_ERR;
    BFSharedArrayNode *n = node_new(object);
    if (!n)
        return BF_ERR;

    pthread_mutex_lock(&array->mutex);
    if (index > array->count) {
        pthread_mutex_unlock(&array->mutex);
        node_free(n);
        return BF_ERR;
    }

    if (array->count == 0U) {
        array->head = array->tail = n;
        array->count              = 1U;
        int ret                   = 0;
        pthread_mutex_unlock(&array->mutex);
        ret = size_to_index(0U);
        return ret;
    }

    if (index == 0U) {
        // insert at head
        n->next           = array->head;
        array->head->prev = n;
        array->head       = n;
    } else if (index == array->count) {
        // append at tail
        n->prev           = array->tail;
        array->tail->next = n;
        array->tail       = n;
    } else {
        BFSharedArrayNode *at = get_node_at_locked(array, index);
        if (!at) {
            pthread_mutex_unlock(&array->mutex);
            node_free(n);
            return BF_ERR;
        }
        n->prev        = at->prev;
        n->next        = at;
        at->prev->next = n;
        at->prev       = n;
    }
    array->count++;
    size_t inserted_index = index;
    pthread_mutex_unlock(&array->mutex);
    return size_to_index(inserted_index);
}

int BFSharedArrayPush(BFSharedArray *array, void *object) {
    if (!array)
        return BF_ERR;
    pthread_mutex_lock(&array->mutex);
    size_t idx = array->count;
    pthread_mutex_unlock(&array->mutex);
    return BFSharedArrayInsert(array, idx, object);
}

int BFSharedArrayUnshift(BFSharedArray *array, void *object) {
    return BFSharedArrayInsert(array, 0U, object);
}

void *BFSharedArrayGet(BFSharedArray *array, size_t index) {
    if (!array)
        return NULL;
    pthread_mutex_lock(&array->mutex);
    BFSharedArrayNode *at = get_node_at_locked(array, index);
    void              *v  = at ? at->value : NULL;
    pthread_mutex_unlock(&array->mutex);
    return v;
}

void *BFSharedArraySet(BFSharedArray *array, size_t index, void *object) {
    if (!array)
        return NULL;
    pthread_mutex_lock(&array->mutex);
    BFSharedArrayNode *at = get_node_at_locked(array, index);
    if (!at) {
        pthread_mutex_unlock(&array->mutex);
        return NULL;
    }
    void *old = at->value;
    at->value = object;
    pthread_mutex_unlock(&array->mutex);
    return old;
}

void *BFSharedArrayRemoveAt(BFSharedArray *array, size_t index) {
    if (!array)
        return NULL;
    pthread_mutex_lock(&array->mutex);
    BFSharedArrayNode *at = get_node_at_locked(array, index);
    if (!at) {
        pthread_mutex_unlock(&array->mutex);
        return NULL;
    }
    if (at->prev)
        at->prev->next = at->next;
    else
        array->head = at->next;

    if (at->next)
        at->next->prev = at->prev;
    else
        array->tail = at->prev;

    array->count--;
    void *val = at->value;
    pthread_mutex_unlock(&array->mutex);
    node_free(at);
    return val;
}

int BFSharedArrayClear(BFSharedArray *array) {
    if (!array)
        return BF_ERR;
    pthread_mutex_lock(&array->mutex);
    BFSharedArrayNode *p = array->head;
    array->head          = NULL;
    array->tail          = NULL;
    array->count         = 0U;
    pthread_mutex_unlock(&array->mutex);

    while (p) {
        BFSharedArrayNode *next = p->next;
        if (array->destroy_cb && p->value) {
            array->destroy_cb(p->value);
        }
        node_free(p);
        p = next;
    }
    return BF_OK;
}
