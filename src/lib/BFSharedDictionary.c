#include "box/BFSharedDictionary.h"

#include "box/BFCommon.h"
#include "box/BFMemory.h"

#include <pthread.h>
#include <string.h>

typedef struct BFDictNode {
    char              *key;   // duplicated
    void              *value; // stored pointer
    struct BFDictNode *next;
} BFDictNode;

struct BFSharedDictionary {
    pthread_mutex_t               mutex;
    BFDictNode                  **buckets;
    size_t                        bucketCount;
    size_t                        count;
    BFSharedDictionaryDestroyValue destroy_cb; // optional
};

static unsigned long djb2(const char *s) {
    unsigned long h = 5381UL;
    int           c = 0;
    while (s && (c = *s++) != 0) {
        h = ((h << 5) + h) + (unsigned long)c; // h*33 + c
    }
    return h;
}

static size_t pick_bucket(const char *key, size_t bucketCount) {
    unsigned long h = djb2(key);
    return (size_t)(h % (bucketCount ? bucketCount : 1U));
}

static char *dup_cstr(const char *s) {
    if (!s)
        return NULL;
    size_t n  = strlen(s);
    char  *cp = (char *)BFMemoryAllocate(n + 1U);
    if (!cp)
        return NULL;
    memcpy(cp, s, n);
    cp[n] = '\0';
    return cp;
}

BFSharedDictionary *BFSharedDictionaryCreate(BFSharedDictionaryDestroyValue destroy_cb) {
    const size_t buckets = 256U; // simple default
    BFSharedDictionary *d = (BFSharedDictionary *)BFMemoryAllocate(sizeof(*d));
    if (!d)
        return NULL;
    d->buckets = (BFDictNode **)BFMemoryAllocate(sizeof(BFDictNode *) * buckets);
    if (!d->buckets) {
        BFMemoryRelease(d);
        return NULL;
    }
    memset(d->buckets, 0, sizeof(BFDictNode *) * buckets);
    d->bucketCount = buckets;
    d->count       = 0U;
    d->destroy_cb  = destroy_cb;
    (void)pthread_mutex_init(&d->mutex, NULL);
    return d;
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
    size_t n = dict->count;
    pthread_mutex_unlock(&dict->mutex);
    return n;
}

int BFSharedDictionarySet(BFSharedDictionary *dict, const char *key, void *value) {
    if (!dict || !key)
        return BF_ERR;
    size_t b = pick_bucket(key, dict->bucketCount);

    pthread_mutex_lock(&dict->mutex);
    BFDictNode *p = dict->buckets[b];
    while (p) {
        if (strcmp(p->key, key) == 0) {
            // replace
            if (dict->destroy_cb && p->value && p->value != value) {
                dict->destroy_cb(p->value);
            }
            p->value = value;
            pthread_mutex_unlock(&dict->mutex);
            return BF_OK;
        }
        p = p->next;
    }
    // insert new at head
    BFDictNode *n = (BFDictNode *)BFMemoryAllocate(sizeof(*n));
    if (!n) {
        pthread_mutex_unlock(&dict->mutex);
        return BF_ERR;
    }
    n->key   = dup_cstr(key);
    n->value = value;
    n->next  = dict->buckets[b];
    dict->buckets[b] = n;
    dict->count++;
    pthread_mutex_unlock(&dict->mutex);
    return BF_OK;
}

void *BFSharedDictionaryGet(BFSharedDictionary *dict, const char *key) {
    if (!dict || !key)
        return NULL;
    size_t b = pick_bucket(key, dict->bucketCount);
    pthread_mutex_lock(&dict->mutex);
    BFDictNode *p = dict->buckets[b];
    while (p) {
        if (strcmp(p->key, key) == 0) {
            void *v = p->value;
            pthread_mutex_unlock(&dict->mutex);
            return v;
        }
        p = p->next;
    }
    pthread_mutex_unlock(&dict->mutex);
    return NULL;
}

void *BFSharedDictionaryRemove(BFSharedDictionary *dict, const char *key) {
    if (!dict || !key)
        return NULL;
    size_t b = pick_bucket(key, dict->bucketCount);
    pthread_mutex_lock(&dict->mutex);
    BFDictNode *p = dict->buckets[b];
    BFDictNode *q = NULL;
    while (p) {
        if (strcmp(p->key, key) == 0) {
            if (q)
                q->next = p->next;
            else
                dict->buckets[b] = p->next;
            dict->count--;
            void *val = p->value;
            char *k    = p->key;
            pthread_mutex_unlock(&dict->mutex);
            BFMemoryRelease(k);
            BFMemoryRelease(p);
            return val;
        }
        q = p;
        p = p->next;
    }
    pthread_mutex_unlock(&dict->mutex);
    return NULL;
}

int BFSharedDictionaryClear(BFSharedDictionary *dict) {
    if (!dict)
        return BF_ERR;
    pthread_mutex_lock(&dict->mutex);
    BFDictNode **b = dict->buckets;
    size_t       N = dict->bucketCount;
    dict->count    = 0U;
    dict->buckets  = b; // unchanged
    pthread_mutex_unlock(&dict->mutex);

    for (size_t i = 0; i < N; ++i) {
        BFDictNode *p = b[i];
        b[i]          = NULL;
        while (p) {
            BFDictNode *nxt = p->next;
            if (dict->destroy_cb && p->value)
                dict->destroy_cb(p->value);
            BFMemoryRelease(p->key);
            BFMemoryRelease(p);
            p = nxt;
        }
    }
    return BF_OK;
}

