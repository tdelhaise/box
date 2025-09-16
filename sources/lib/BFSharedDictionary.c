#include "BFSharedDictionary.h"

#include "BFCommon.h"
#include "BFMemory.h"

#include <pthread.h>
#include <string.h>

typedef struct BFDictionaryNode {
    char                    *key;   // duplicated
    void                    *value; // stored pointer
    struct BFDictionaryNode *next;
} BFDictionaryNode;

struct BFSharedDictionary {
    pthread_mutex_t                mutex;
	BFDictionaryNode               **buckets;
    size_t                         bucketCount;
    size_t                         count;
    BFSharedDictionaryDestroyValue destroyCallback; // optional
};

static unsigned long BFSharedDictionaryHashValueFromString(const char *string) {
    unsigned long hashValue = 5381UL;
    int           character = 0;
    while (string && (character = *string++) != 0) {
        hashValue = ((hashValue << 5) + hashValue) + (unsigned long)character; // h*33 + c
    }
    return hashValue;
}

static size_t BFSharedDictionaryPickBucket(const char *key, size_t bucketCount) {
    unsigned long hashValue = BFSharedDictionaryHashValueFromString(key);
    return (size_t)(hashValue % (bucketCount ? bucketCount : 1U));
}

static char *BFSharedDictionaryDuplicateCString(const char *string) {
    if (!string)
        return NULL;
    size_t length  = strlen(string);
    char  *copyPointer = (char *)BFMemoryAllocate(length + 1U);
    if (!copyPointer)
        return NULL;
	memcpy(copyPointer, string, length);
	copyPointer[length] = '\0';
    return copyPointer;
}

BFSharedDictionary *BFSharedDictionaryCreate(BFSharedDictionaryDestroyValue destroyCallback) {
    const size_t        buckets    = 256U; // simple default
    BFSharedDictionary *dictionary = (BFSharedDictionary *)BFMemoryAllocate(sizeof(BFSharedDictionary));
	if (!dictionary) {
		return NULL;
	}
    dictionary->buckets = (BFDictionaryNode **)BFMemoryAllocate(sizeof(BFDictionaryNode *) * buckets);
    if (!dictionary->buckets) {
        BFMemoryRelease(dictionary);
        return NULL;
    }
    memset(dictionary->buckets, 0, sizeof(BFDictionaryNode *) * buckets);
    dictionary->bucketCount = buckets;
    dictionary->count       = 0U;
    dictionary->destroyCallback  = destroyCallback;
    (void)pthread_mutex_init(&dictionary->mutex, NULL);
    return dictionary;
}

void BFSharedDictionaryFree(BFSharedDictionary *sharedDictionary) {
	if (!sharedDictionary) {
		return;
	}
    (void)BFSharedDictionaryClear(sharedDictionary);
    BFMemoryRelease(sharedDictionary->buckets);
    pthread_mutex_destroy(&sharedDictionary->mutex);
    BFMemoryRelease(sharedDictionary);
}

size_t BFSharedDictionaryCount(BFSharedDictionary *sharedDictionary) {
	if (!sharedDictionary) {
		return 0U;
	}
    pthread_mutex_lock(&sharedDictionary->mutex);
    size_t currentCount = sharedDictionary->count;
    pthread_mutex_unlock(&sharedDictionary->mutex);
    return currentCount;
}

int BFSharedDictionarySet(BFSharedDictionary *dictionary, const char *key, void *value) {
    if (!dictionary || !key)
        return BF_ERR;
    size_t bucketIndex = BFSharedDictionaryPickBucket(key, dictionary->bucketCount);

    pthread_mutex_lock(&dictionary->mutex);
    BFDictionaryNode *currentNode = dictionary->buckets[bucketIndex];
    while (currentNode) {
        if (strcmp(currentNode->key, key) == 0) {
            // replace
            if (dictionary->destroyCallback && currentNode->value && currentNode->value != value) {
				dictionary->destroyCallback(currentNode->value);
            }
            currentNode->value = value;
            pthread_mutex_unlock(&dictionary->mutex);
            return BF_OK;
        }
        currentNode = currentNode->next;
    }
    // insert new at head
    BFDictionaryNode *newNode = (BFDictionaryNode *)BFMemoryAllocate(sizeof(*newNode));
    if (!newNode) {
        pthread_mutex_unlock(&dictionary->mutex);
        return BF_ERR;
    }
    newNode->key               = BFSharedDictionaryDuplicateCString(key);
    newNode->value             = value;
    newNode->next              = dictionary->buckets[bucketIndex];
	dictionary->buckets[bucketIndex] = newNode;
	dictionary->count++;
    pthread_mutex_unlock(&dictionary->mutex);
    return BF_OK;
}

void *BFSharedDictionaryGet(BFSharedDictionary *dictionary, const char *key) {
	if (!dictionary || !key) {
		return NULL;
	}
    size_t bucketIndex = BFSharedDictionaryPickBucket(key, dictionary->bucketCount);
    pthread_mutex_lock(&dictionary->mutex);
    BFDictionaryNode *currentNode = dictionary->buckets[bucketIndex];
    while (currentNode) {
        if (strcmp(currentNode->key, key) == 0) {
            void *value = currentNode->value;
            pthread_mutex_unlock(&dictionary->mutex);
            return value;
        }
        currentNode = currentNode->next;
    }
    pthread_mutex_unlock(&dictionary->mutex);
    return NULL;
}

void *BFSharedDictionaryRemove(BFSharedDictionary *dictionary, const char *key) {
	if (!dictionary || !key) {
		return NULL;
	}
    size_t bucketIndex = BFSharedDictionaryPickBucket(key, dictionary->bucketCount);
    pthread_mutex_lock(&dictionary->mutex);
    BFDictionaryNode *currentNode  = dictionary->buckets[bucketIndex];
    BFDictionaryNode *previousNode = NULL;
    while (currentNode) {
        if (strcmp(currentNode->key, key) == 0) {
			if (previousNode) {
				previousNode->next = currentNode->next;
			} else {
				dictionary->buckets[bucketIndex] = currentNode->next;
			}
			dictionary->count--;
            void *value   = currentNode->value;
            char *keyCopy = currentNode->key;
            pthread_mutex_unlock(&dictionary->mutex);
            BFMemoryRelease(keyCopy);
            BFMemoryRelease(currentNode);
            return value;
        }
        previousNode = currentNode;
        currentNode  = currentNode->next;
    }
    pthread_mutex_unlock(&dictionary->mutex);
    return NULL;
}

int BFSharedDictionaryClear(BFSharedDictionary *dictionary) {
    if (!dictionary)
        return BF_ERR;
    pthread_mutex_lock(&dictionary->mutex);
    BFDictionaryNode **buckets        = dictionary->buckets;
    size_t       bucketCapacity = dictionary->bucketCount;
	dictionary->count                 = 0U;
	dictionary->buckets               = buckets; // unchanged
    pthread_mutex_unlock(&dictionary->mutex);

    for (size_t bucketIndex = 0; bucketIndex < bucketCapacity; ++bucketIndex) {
        BFDictionaryNode *currentNode = buckets[bucketIndex];
        buckets[bucketIndex]    = NULL;
        while (currentNode) {
            BFDictionaryNode *nextNode = currentNode->next;
			if (dictionary->destroyCallback && currentNode->value)
				dictionary->destroyCallback(currentNode->value);
            BFMemoryRelease(currentNode->key);
            BFMemoryRelease(currentNode);
            currentNode = nextNode;
        }
    }
    return BF_OK;
}
