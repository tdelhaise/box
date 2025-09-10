#include "box/BFMemory.h"
#include "box/BFSharedArray.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

typedef struct IntBox {
    int value;
} IntBox;

static int g_destroyed = 0;

static void destroy_intbox(void *ptr) {
    if (ptr) {
        g_destroyed++;
        BFMemoryRelease(ptr);
    }
}

static IntBox *make_int(int v) {
    IntBox *p = (IntBox *)BFMemoryAllocate(sizeof(IntBox));
    assert(p != NULL);
    p->value = v;
    return p;
}

int main(void) {
    g_destroyed      = 0;
    BFSharedArray *a = BFSharedArrayCreate(destroy_intbox);
    assert(a != NULL);
    assert(BFSharedArrayCount(a) == 0U);

    // Push and unshift
    assert(BFSharedArrayPush(a, make_int(1)) == 0);
    assert(BFSharedArrayPush(a, make_int(2)) == 1);
    assert(BFSharedArrayUnshift(a, make_int(0)) == 0);
    assert(BFSharedArrayCount(a) == 3U);

    // Insert before index 2
    assert(BFSharedArrayInsert(a, 2U, make_int(99)) == 2);
    assert(BFSharedArrayCount(a) == 4U);

    // Validate order: [0,1,99,2]
    IntBox *b0 = (IntBox *)BFSharedArrayGet(a, 0U);
    IntBox *b1 = (IntBox *)BFSharedArrayGet(a, 1U);
    IntBox *b2 = (IntBox *)BFSharedArrayGet(a, 2U);
    IntBox *b3 = (IntBox *)BFSharedArrayGet(a, 3U);
    assert(b0 && b0->value == 0);
    assert(b1 && b1->value == 1);
    assert(b2 && b2->value == 99);
    assert(b3 && b3->value == 2);

    // Set index 2 to 3, free old value
    IntBox *old = (IntBox *)BFSharedArraySet(a, 2U, make_int(3));
    assert(old && old->value == 99);
    BFMemoryRelease(old);

    // RemoveAt index 1 returns the element (value 1); free it
    IntBox *rem = (IntBox *)BFSharedArrayRemoveAt(a, 1U);
    assert(rem && rem->value == 1);
    BFMemoryRelease(rem);
    assert(BFSharedArrayCount(a) == 3U);

    // Validate order now: [0,3,2]
    b0 = (IntBox *)BFSharedArrayGet(a, 0U);
    b1 = (IntBox *)BFSharedArrayGet(a, 1U);
    b2 = (IntBox *)BFSharedArrayGet(a, 2U);
    assert(b0 && b0->value == 0);
    assert(b1 && b1->value == 3);
    assert(b2 && b2->value == 2);

    // Out-of-bounds insert should fail; free manually the object we attempted to insert
    IntBox *tmp = make_int(7);
    assert(BFSharedArrayInsert(a, 1000U, tmp) == -1);
    BFMemoryRelease(tmp);

    // Clear should destroy remaining 3 elements
    assert(BFSharedArrayClear(a) == 0);
    assert(BFSharedArrayCount(a) == 0U);
    assert(g_destroyed >= 3); // at least the remaining three were destroyed

    BFSharedArrayFree(a);
    printf("test_BFSharedArray: OK\n");
    return 0;
}
