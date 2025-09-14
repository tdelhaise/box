#include "BFSharedDictionary.h"

#include "BFCommon.h"
#include "BFMemory.h"

#include <pthread.h>
#include <string.h>

typedef struct BFDictNode {
    char              *key;   // duplicated
    void              *value; // stored pointer
    struct BFDictNode *next;
} BFDictNode;

struct BFSharedDictionary {
    pthread_mutex_t                mutex;
    BFDictNode                   **buckets;
    size_t                         bucketCount;
    size_t                         count;
    BFSharedDictionaryDestroyValue destroy_cb; // optional
};

static unsigned long djb2(const char *s) {
    unsigned long hashValue = 5381UL;
    int           character = 0;
    while (s && (character = *s++) != 0) {
        hashValue = ((hashValue << 5) + hashValue) + (unsigned long)character; // h*33 + c
    }
    return hashValue;
}

static size_t pick_bucket(const char *key, size_t bucketCount) {
    unsigned long hashValue = djb2(key);
    return (size_t)(hashValue % (bucketCount ? bucketCount : 1U));
}

static char *dup_cstr(const char *s) {
    if (!s)
        return NULL;
    size_t length  = strlen(s);
    char  *copyPtr = (char *)BFMemoryAllocate(length + 1U);
    if (!copyPtr)
        return NULL;
    memcpy(copyPtr, s, length);
    copyPtr[length] = '\0';
    return copyPtr;
}

BFSharedDictionary *BFSharedDictionaryCreate(BFSharedDictionaryDestroyValue destroy_cb) {
    const size_t        buckets    = 256U; // simple default
    BFSharedDictionary *dictionary = (BFSharedDictionary *)BFMemoryAllocate(sizeof(*dictionary));
    if (!dictionary)
        return NULL;
    dictionary->buckets = (BFDictNode **)BFMemoryAllocate(sizeof(BFDictNode *) * buckets);
    if (!dictionary->buckets) {
        BFMemoryRelease(dictionary);
        return NULL;
    }
    memset(dictionary->buckets, 0, sizeof(BFDictNode *) * buckets);
    dictionary->bucketCount = buckets;
    dictionary->count       = 0U;
    dictionary->destroy_cb  = destroy_cb;
    (void)pthread_mutex_init(&dictionary->mutex, NULL);
    return dictionary;
}

void BFSharedDictionaryFree(BFSharedDictionary *dict) {
    if (!dict)
        return;
    (void)BFSharedDictionaryClear(dict);
    BFMemoryRelease(dict->buckets);
    pthread_mutex_destroy(&dict->mutex);
    BFMemoryRelease(dict);
}

size_t BFSharedDictionaryCount(BFSharedDictionary *dict) {
    if (!dict)
        return 0U;
    pthread_mutex_lock(&dict->mutex);
    size_t currentCount = dict->count;
    pthread_mutex_unlock(&dict->mutex);
    return currentCount;
}

int BFSharedDictionarySet(BFSharedDictionary *dict, const char *key, void *value) {
    if (!dict || !key)
        return BF_ERR;
    size_t bucketIndex = pick_bucket(key, dict->bucketCount);

    pthread_mutex_lock(&dict->mutex);
    BFDictNode *currentNode = dict->buckets[bucketIndex];
    while (currentNode) {
        if (strcmp(currentNode->key, key) == 0) {
            // replace
            if (dict->destroy_cb && currentNode->value && currentNode->value != value) {
                dict->destroy_cb(currentNode->value);
            }
            currentNode->value = value;
            pthread_mutex_unlock(&dict->mutex);
            return BF_OK;
        }
        currentNode = currentNode->next;
    }
    // insert new at head
    BFDictNode *newNode = (BFDictNode *)BFMemoryAllocate(sizeof(*newNode));
    if (!newNode) {
        pthread_mutex_unlock(&dict->mutex);
        return BF_ERR;
    }
    newNode->key               = dup_cstr(key);
    newNode->value             = value;
    newNode->next              = dict->buckets[bucketIndex];
    dict->buckets[bucketIndex] = newNode;
    dict->count++;
    pthread_mutex_unlock(&dict->mutex);
    return BF_OK;
}

void *BFSharedDictionaryGet(BFSharedDictionary *dict, const char *key) {
    if (!dict || !key)
        return NULL;
    size_t bucketIndex = pick_bucket(key, dict->bucketCount);
    pthread_mutex_lock(&dict->mutex);
    BFDictNode *currentNode = dict->buckets[bucketIndex];
    while (currentNode) {
        if (strcmp(currentNode->key, key) == 0) {
            void *value = currentNode->value;
            pthread_mutex_unlock(&dict->mutex);
            return value;
        }
        currentNode = currentNode->next;
    }
    pthread_mutex_unlock(&dict->mutex);
    return NULL;
}

void *BFSharedDictionaryRemove(BFSharedDictionary *dict, const char *key) {
    if (!dict || !key)
        return NULL;
    size_t bucketIndex = pick_bucket(key, dict->bucketCount);
    pthread_mutex_lock(&dict->mutex);
    BFDictNode *currentNode  = dict->buckets[bucketIndex];
    BFDictNode *previousNode = NULL;
    while (currentNode) {
        if (strcmp(currentNode->key, key) == 0) {
            if (previousNode)
                previousNode->next = currentNode->next;
            else
                dict->buckets[bucketIndex] = currentNode->next;
            dict->count--;
            void *value   = currentNode->value;
            char *keyCopy = currentNode->key;
            pthread_mutex_unlock(&dict->mutex);
            BFMemoryRelease(keyCopy);
            BFMemoryRelease(currentNode);
            return value;
        }
        previousNode = currentNode;
        currentNode  = currentNode->next;
    }
    pthread_mutex_unlock(&dict->mutex);
    return NULL;
}

int BFSharedDictionaryClear(BFSharedDictionary *dict) {
    if (!dict)
        return BF_ERR;
    pthread_mutex_lock(&dict->mutex);
    BFDictNode **buckets        = dict->buckets;
    size_t       bucketCapacity = dict->bucketCount;
    dict->count                 = 0U;
    dict->buckets               = buckets; // unchanged
    pthread_mutex_unlock(&dict->mutex);

    for (size_t bucketIndex = 0; bucketIndex < bucketCapacity; ++bucketIndex) {
        BFDictNode *currentNode = buckets[bucketIndex];
        buckets[bucketIndex]    = NULL;
        while (currentNode) {
            BFDictNode *nextNode = currentNode->next;
            if (dict->destroy_cb && currentNode->value)
                dict->destroy_cb(currentNode->value);
            BFMemoryRelease(currentNode->key);
            BFMemoryRelease(currentNode);
            currentNode = nextNode;
        }
    }
    return BF_OK;
}
