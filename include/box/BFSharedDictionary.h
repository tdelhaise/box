// BFSharedDictionary — thread-safe string-keyed dictionary (key: const char*, value: void*)
// - Internally duplicates keys (BFMemory), and optionally destroys values via callback on Clear/Free.
// - Single mutex guards the whole table for simplicity and correctness.

#ifndef BF_SHARED_DICTIONARY_H
#define BF_SHARED_DICTIONARY_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BFSharedDictionary BFSharedDictionary;

typedef void (*BFSharedDictionaryDestroyValue)(void *value);

// Lifecycle
BFSharedDictionary *BFSharedDictionaryCreate(BFSharedDictionaryDestroyValue destroy_cb);
void                BFSharedDictionaryFree(BFSharedDictionary *dict);

// Query
size_t BFSharedDictionaryCount(BFSharedDictionary *dict);

// Set/Insert: inserts or replaces value for key. Returns 0 on success, BF_ERR on failure.
int    BFSharedDictionarySet(BFSharedDictionary *dict, const char *key, void *value);

// Get: returns stored value pointer or NULL if not found.
void  *BFSharedDictionaryGet(BFSharedDictionary *dict, const char *key);

// Remove: removes entry and returns the stored value (caller owns it), or NULL if not found.
void  *BFSharedDictionaryRemove(BFSharedDictionary *dict, const char *key);

// Clear all entries; calls destroy_cb on each value if provided.
int    BFSharedDictionaryClear(BFSharedDictionary *dict);

#ifdef __cplusplus
}
#endif

#endif // BF_SHARED_DICTIONARY_H

