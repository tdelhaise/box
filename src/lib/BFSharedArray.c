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
    BFSharedArrayNode *newNode = (BFSharedArrayNode *)BFMemoryAllocate(sizeof(*newNode));
    if (!newNode)
        return NULL;
    newNode->value = value;
    newNode->prev  = NULL;
    newNode->next  = NULL;
    return newNode;
}

static void node_free(BFSharedArrayNode *n) {
    BFMemoryRelease(n);
}

static BFSharedArrayNode *get_node_at_locked(BFSharedArray *a, size_t index) {
    if (index >= a->count)
        return NULL;
    // bidirectional walk for efficiency
    if (index < a->count / 2U) {
        BFSharedArrayNode *cursor = a->head;
        for (size_t walkIndex = 0; cursor && walkIndex < index; ++walkIndex)
            cursor = cursor->next;
        return cursor;
    } else {
        BFSharedArrayNode *cursor = a->tail;
        for (size_t walkIndex = a->count - 1U; cursor && walkIndex > index; --walkIndex)
            cursor = cursor->prev;
        return cursor;
    }
}

BFSharedArray *BFSharedArrayCreate(BFSharedArrayDestroy destroy_cb) {
    BFSharedArray *arrayInstance = (BFSharedArray *)BFMemoryAllocate(sizeof(*arrayInstance));
    if (!arrayInstance)
        return NULL;
    memset(arrayInstance, 0, sizeof(*arrayInstance));
    (void)pthread_mutex_init(&arrayInstance->mutex, NULL);
    arrayInstance->destroy_cb = destroy_cb;
    return arrayInstance;
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
    size_t currentCount = array->count;
    pthread_mutex_unlock(&array->mutex);
    return currentCount;
}

static int size_to_index(size_t sizeIndex) {
    if (sizeIndex > (size_t)INT_MAX)
        return BF_ERR;
    return (int)sizeIndex;
}

int BFSharedArrayInsert(BFSharedArray *array, size_t index, void *object) {
    if (!array)
        return BF_ERR;
    BFSharedArrayNode *newNode = node_new(object);
    if (!newNode)
        return BF_ERR;

    pthread_mutex_lock(&array->mutex);
    if (index > array->count) {
        pthread_mutex_unlock(&array->mutex);
        node_free(newNode);
        return BF_ERR;
    }

    if (array->count == 0U) {
        array->head = array->tail = newNode;
        array->count              = 1U;
        int indexReturn           = 0;
        pthread_mutex_unlock(&array->mutex);
        indexReturn = size_to_index(0U);
        return indexReturn;
    }

    if (index == 0U) {
        // insert at head
        newNode->next     = array->head;
        array->head->prev = newNode;
        array->head       = newNode;
    } else if (index == array->count) {
        // append at tail
        newNode->prev     = array->tail;
        array->tail->next = newNode;
        array->tail       = newNode;
    } else {
        BFSharedArrayNode *at = get_node_at_locked(array, index);
        if (!at) {
            pthread_mutex_unlock(&array->mutex);
            node_free(newNode);
            return BF_ERR;
        }
        newNode->prev  = at->prev;
        newNode->next  = at;
        at->prev->next = newNode;
        at->prev       = newNode;
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
    size_t currentCountIndex = array->count;
    pthread_mutex_unlock(&array->mutex);
    return BFSharedArrayInsert(array, currentCountIndex, object);
}

int BFSharedArrayUnshift(BFSharedArray *array, void *object) {
    return BFSharedArrayInsert(array, 0U, object);
}

void *BFSharedArrayGet(BFSharedArray *array, size_t index) {
    if (!array)
        return NULL;
    pthread_mutex_lock(&array->mutex);
    BFSharedArrayNode *at    = get_node_at_locked(array, index);
    void              *value = at ? at->value : NULL;
    pthread_mutex_unlock(&array->mutex);
    return value;
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
    void *previousValue = at->value;
    at->value           = object;
    pthread_mutex_unlock(&array->mutex);
    return previousValue;
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
    void *value = at->value;
    pthread_mutex_unlock(&array->mutex);
    node_free(at);
    return value;
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
