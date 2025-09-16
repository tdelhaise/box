#include "BFSharedArray.h"

#include "BFCommon.h"
#include "BFMemory.h"

#include <limits.h>
#include <pthread.h>
#include <string.h>

typedef struct BFSharedArrayNode {
    void                     *value;
    struct BFSharedArrayNode *previous;
    struct BFSharedArrayNode *next;
} BFSharedArrayNode;

struct BFSharedArray {
    pthread_mutex_t      mutex;
    BFSharedArrayNode   *head;
    BFSharedArrayNode   *tail;
    size_t               count;
    BFSharedArrayDestroy destroyCallback; // optional
};

static BFSharedArrayNode *BFSharedArrayNodeNew(void *value) {
    BFSharedArrayNode *newNode = (BFSharedArrayNode *)BFMemoryAllocate(sizeof(*newNode));
	if (!newNode) {
		return NULL;
	}
    newNode->value = value;
    newNode->previous  = NULL;
    newNode->next  = NULL;
    return newNode;
}

static void BFSharedArrayNodeFree(BFSharedArrayNode *arrayNode) {
    BFMemoryRelease(arrayNode);
}

static BFSharedArrayNode *BFSharedArrayGetNodeAtLocked(BFSharedArray *sharedArray, size_t index) {
    if (index >= sharedArray->count)
        return NULL;
    // bidirectional walk for efficiency
    if (index < sharedArray->count / 2U) {
        BFSharedArrayNode *cursor = sharedArray->head;
		for (size_t walkIndex = 0; cursor && walkIndex < index; ++walkIndex) {
			cursor = cursor->next;
		}
        return cursor;
    } else {
        BFSharedArrayNode *cursor = sharedArray->tail;
		for (size_t walkIndex = sharedArray->count - 1U; cursor && walkIndex > index; --walkIndex) {
			cursor = cursor->previous;
		}
        return cursor;
    }
}

BFSharedArray *BFSharedArrayCreate(BFSharedArrayDestroy destroyCallback) {
    BFSharedArray *arrayInstance = (BFSharedArray *)BFMemoryAllocate(sizeof(BFSharedArray));
	if (!arrayInstance) {
		return NULL;
	}
    memset(arrayInstance, 0, sizeof(BFSharedArray));
    (void)pthread_mutex_init(&arrayInstance->mutex, NULL);
    arrayInstance->destroyCallback = destroyCallback;
    return arrayInstance;
}

void BFSharedArrayFree(BFSharedArray *array) {
	if (!array) {
		return;
	}
    (void)BFSharedArrayClear(array);
    pthread_mutex_destroy(&array->mutex);
    BFMemoryRelease(array);
}

size_t BFSharedArrayCount(BFSharedArray *array) {
	if (!array) {
		return 0;
	}
    pthread_mutex_lock(&array->mutex);
    size_t currentCount = array->count;
    pthread_mutex_unlock(&array->mutex);
    return currentCount;
}

static int BFSharedArraySizeToIndex(size_t sizeIndex) {
	if (sizeIndex > (size_t)INT_MAX) {
		return BF_ERR;
	}
    return (int)sizeIndex;
}

int BFSharedArrayInsert(BFSharedArray *array, size_t index, void *object) {
	if (!array) {
		return BF_ERR;
	}
    BFSharedArrayNode *newNode = BFSharedArrayNodeNew(object);
	if (!newNode) {
		return BF_ERR;
	}

    pthread_mutex_lock(&array->mutex);
    if (index > array->count) {
        pthread_mutex_unlock(&array->mutex);
		BFSharedArrayNodeFree(newNode);
        return BF_ERR;
    }

    if (array->count == 0U) {
        array->head = array->tail = newNode;
        array->count              = 1U;
        int indexReturn           = 0;
        pthread_mutex_unlock(&array->mutex);
        indexReturn = BFSharedArraySizeToIndex(0U);
        return indexReturn;
    }

    if (index == 0U) {
        // insert at head
        newNode->next         = array->head;
        array->head->previous = newNode;
        array->head           = newNode;
    } else if (index == array->count) {
        // append at tail
        newNode->previous = array->tail;
        array->tail->next = newNode;
        array->tail       = newNode;
    } else {
        BFSharedArrayNode *arrayNodeAtIndex = BFSharedArrayGetNodeAtLocked(array, index);
        if (!arrayNodeAtIndex) {
            pthread_mutex_unlock(&array->mutex);
			BFSharedArrayNodeFree(newNode);
            return BF_ERR;
        }
        newNode->previous  = arrayNodeAtIndex->previous;
        newNode->next  = arrayNodeAtIndex;
		arrayNodeAtIndex->previous->next = newNode;
		arrayNodeAtIndex->previous       = newNode;
    }
    array->count++;
    size_t insertedIndex = index;
    pthread_mutex_unlock(&array->mutex);
    return BFSharedArraySizeToIndex(insertedIndex);
}

int BFSharedArrayPush(BFSharedArray *array, void *object) {
	if (!array) {
		return BF_ERR;
	}
    pthread_mutex_lock(&array->mutex);
    size_t currentCountIndex = array->count;
    pthread_mutex_unlock(&array->mutex);
    return BFSharedArrayInsert(array, currentCountIndex, object);
}

int BFSharedArrayUnshift(BFSharedArray *array, void *object) {
    return BFSharedArrayInsert(array, 0U, object);
}

void *BFSharedArrayGet(BFSharedArray *array, size_t index) {
	if (!array) {
		return NULL;
	}
    pthread_mutex_lock(&array->mutex);
    BFSharedArrayNode *arrayNodeAtIndex = BFSharedArrayGetNodeAtLocked(array, index);
    void              *value = arrayNodeAtIndex ? arrayNodeAtIndex->value : NULL;
    pthread_mutex_unlock(&array->mutex);
    return value;
}

void *BFSharedArraySet(BFSharedArray *array, size_t index, void *object) {
	if (!array) {
		return NULL;
	}
    pthread_mutex_lock(&array->mutex);
    BFSharedArrayNode *arrayNodeAtIndex = BFSharedArrayGetNodeAtLocked(array, index);
    if (!arrayNodeAtIndex) {
        pthread_mutex_unlock(&array->mutex);
        return NULL;
    }
    void *previousValue = arrayNodeAtIndex->value;
	arrayNodeAtIndex->value           = object;
    pthread_mutex_unlock(&array->mutex);
    return previousValue;
}

void *BFSharedArrayRemoveAt(BFSharedArray *array, size_t index) {
	if (!array) {
		return NULL;
	}
    pthread_mutex_lock(&array->mutex);
    BFSharedArrayNode *arrayNodeAtIndex = BFSharedArrayGetNodeAtLocked(array, index);
    if (!arrayNodeAtIndex) {
        pthread_mutex_unlock(&array->mutex);
        return NULL;
    }
	if (arrayNodeAtIndex->previous) {
		arrayNodeAtIndex->previous->next = arrayNodeAtIndex->next;
	} else {
		array->head = arrayNodeAtIndex->next;
	}

	if (arrayNodeAtIndex->next) {
		arrayNodeAtIndex->next->previous = arrayNodeAtIndex->previous;
	} else {
		array->tail = arrayNodeAtIndex->previous;
	}

    array->count--;
    void *value = arrayNodeAtIndex->value;
    pthread_mutex_unlock(&array->mutex);
	BFSharedArrayNodeFree(arrayNodeAtIndex);
    return value;
}

int BFSharedArrayClear(BFSharedArray *array) {
	if (!array) {
		return BF_ERR;
	}
    pthread_mutex_lock(&array->mutex);
    BFSharedArrayNode *arrayNode = array->head;
    array->head          = NULL;
    array->tail          = NULL;
    array->count         = 0U;
    pthread_mutex_unlock(&array->mutex);

    while (arrayNode) {
        BFSharedArrayNode *next = arrayNode->next;
        if (array->destroyCallback && arrayNode->value) {
            array->destroyCallback(arrayNode->value);
        }
		BFSharedArrayNodeFree(arrayNode);
		arrayNode = next;
    }
    return BF_OK;
}
