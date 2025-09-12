#include "box/BFMemory.h"
#include "box/BFSharedArray.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

typedef struct IntBox {
    int value;
} IntBox;

static int g_destroyed = 0;

static void destroy_intbox(void *pointer) {
    if (pointer) {
        g_destroyed++;
        BFMemoryRelease(pointer);
    }
}

static IntBox *make_int(int value) {
    IntBox *box = (IntBox *)BFMemoryAllocate(sizeof(IntBox));
    assert(box != NULL);
    box->value = value;
    return box;
}

int main(void) {
    g_destroyed          = 0;
    BFSharedArray *array = BFSharedArrayCreate(destroy_intbox);
    assert(array != NULL);
    assert(BFSharedArrayCount(array) == 0U);

    // Push and unshift
    assert(BFSharedArrayPush(array, make_int(1)) == 0);
    assert(BFSharedArrayPush(array, make_int(2)) == 1);
    assert(BFSharedArrayUnshift(array, make_int(0)) == 0);
    assert(BFSharedArrayCount(array) == 3U);

    // Insert before index 2
    assert(BFSharedArrayInsert(array, 2U, make_int(99)) == 2);
    assert(BFSharedArrayCount(array) == 4U);

    // Validate order: [0,1,99,2]
    IntBox *box0 = (IntBox *)BFSharedArrayGet(array, 0U);
    IntBox *box1 = (IntBox *)BFSharedArrayGet(array, 1U);
    IntBox *box2 = (IntBox *)BFSharedArrayGet(array, 2U);
    IntBox *box3 = (IntBox *)BFSharedArrayGet(array, 3U);
    assert(box0 && box0->value == 0);
    assert(box1 && box1->value == 1);
    assert(box2 && box2->value == 99);
    assert(box3 && box3->value == 2);

    // Set index 2 to 3, free old value
    IntBox *previous = (IntBox *)BFSharedArraySet(array, 2U, make_int(3));
    assert(previous && previous->value == 99);
    BFMemoryRelease(previous);

    // RemoveAt index 1 returns the element (value 1); free it
    IntBox *removed = (IntBox *)BFSharedArrayRemoveAt(array, 1U);
    assert(removed && removed->value == 1);
    BFMemoryRelease(removed);
    assert(BFSharedArrayCount(array) == 3U);

    // Validate order now: [0,3,2]
    box0 = (IntBox *)BFSharedArrayGet(array, 0U);
    box1 = (IntBox *)BFSharedArrayGet(array, 1U);
    box2 = (IntBox *)BFSharedArrayGet(array, 2U);
    assert(box0 && box0->value == 0);
    assert(box1 && box1->value == 3);
    assert(box2 && box2->value == 2);

    // Out-of-bounds insert should fail; free manually the object we attempted to insert
    IntBox *temporary = make_int(7);
    assert(BFSharedArrayInsert(array, 1000U, temporary) == -1);
    BFMemoryRelease(temporary);

    // Clear should destroy remaining 3 elements
    assert(BFSharedArrayClear(array) == 0);
    assert(BFSharedArrayCount(array) == 0U);
    assert(g_destroyed >= 3); // at least the remaining three were destroyed

    BFSharedArrayFree(array);
    printf("test_BFSharedArray: OK\n");
    return 0;
}
