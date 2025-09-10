// BFSharedArray — thread-safe pseudo array backed by a doubly-linked list
// Allows insertion at any position efficiently (O(1) once node found),
// and supports push (end), unshift (front), insert, get, set, remove.
// All memory operations use BFMemory and concurrent access is protected
// by a pthread mutex inside the container.

#ifndef BF_SHARED_ARRAY_H
#define BF_SHARED_ARRAY_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BFSharedArray BFSharedArray;

// Optional destructor for stored objects; called by Clear/Free.
typedef void (*BFSharedArrayDestroy)(void *object);

// Lifecycle
BFSharedArray *BFSharedArrayCreate(BFSharedArrayDestroy destroy_cb);
void           BFSharedArrayFree(BFSharedArray *array); // clears and frees

// Query
size_t BFSharedArrayCount(BFSharedArray *array);

// Insertions
// Default policy is push (append at end).
// Returns the index of the inserted element, or BF_ERR on failure.
int BFSharedArrayPush(BFSharedArray *array, void *object);
int BFSharedArrayUnshift(BFSharedArray *array, void *object); // insert at front (index 0)
int BFSharedArrayInsert(BFSharedArray *array, size_t index, void *object); // insert before index

// Accessors
// Get returns the pointer stored at index or NULL if out of bounds.
void *BFSharedArrayGet(BFSharedArray *array, size_t index);

// Set replaces the element at index, returning the previous pointer (or NULL on error).
// Caller owns the returned previous pointer.
void *BFSharedArraySet(BFSharedArray *array, size_t index, void *object);

// Removal
// Removes the element at index and returns it (or NULL if out of bounds).
// Caller owns the returned pointer and is responsible for disposing it.
void *BFSharedArrayRemoveAt(BFSharedArray *array, size_t index);

// Clears all items; calls destroy_cb for each stored pointer if provided.
int BFSharedArrayClear(BFSharedArray *array);

#ifdef __cplusplus
}
#endif

#endif // BF_SHARED_ARRAY_H

