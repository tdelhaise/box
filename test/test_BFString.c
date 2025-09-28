#include "BFString.h"
#include "BFData.h"
#include "BFCommon.h"

#include <assert.h>
#include <string.h>

static void testCreateAndAssign(void) {
    BFString string = BFStringCreate();
    assert(BFStringGetLength(&string) == 0U);
    assert(strcmp(BFStringGetCString(&string), "") == 0);

    assert(BFStringSetFromCString(&string, "bonjour") == BF_OK);
    assert(BFStringGetLength(&string) == strlen("bonjour"));
    assert(strcmp(BFStringGetCString(&string), "bonjour") == 0);

    const char  sampleBytes[] = { (char)0xE2, (char)0x82, (char)0xAC }; // Euro sign
    BFString     utfString    = BFStringCreateWithUTF8Bytes(sampleBytes, sizeof(sampleBytes));
    assert(BFStringGetLength(&utfString) == sizeof(sampleBytes));
    assert(strcmp(BFStringGetCString(&utfString), "€") == 0);

    assert(BFStringAppendString(&string, &utfString) == BF_OK);
    assert(strcmp(BFStringGetCString(&string), "bonjour€") == 0);

    BFStringReset(&string);
    BFStringReset(&utfString);
}

static void testDataConversions(void) {
    BFString greeting = BFStringCreateWithCString("hello");
    BFData   data     = BFDataCreate(0U);
    assert(BFStringCopyToData(&greeting, &data) == BF_OK);
    assert(BFDataGetLength(&data) == BFStringGetLength(&greeting));
    assert(memcmp(BFDataGetBytes(&data), "hello", 5U) == 0);

    BFString fromData = BFStringCreateWithData(&data);
    assert(BFStringIsEqual(&greeting, &fromData) == 1);

    BFDataReset(&data);
    BFStringReset(&greeting);
    BFStringReset(&fromData);
}

static void testComparison(void) {
    BFString first  = BFStringCreateWithCString("abc");
    BFString second = BFStringCreateWithCString("abd");
    int      cmp    = 0;
    assert(BFStringCompare(&first, &second, &cmp) == BF_OK);
    assert(cmp < 0);

    BFString third = BFStringCreateWithCString("abc");
    assert(BFStringIsEqual(&first, &third) == 1);

    BFStringReset(&first);
    BFStringReset(&second);
    BFStringReset(&third);
}

static void testInvalidUTF8Rejected(void) {
    BFString string = BFStringCreate();
    const char invalidBytes[] = { (char)0xC3, (char)0x28 }; // Invalid continuation
    assert(BFStringSetFromUTF8Bytes(&string, invalidBytes, sizeof(invalidBytes)) == BF_ERR);

    const char embeddedNull[] = { 'a', '\0', 'b' };
    assert(BFStringSetFromUTF8Bytes(&string, embeddedNull, sizeof(embeddedNull)) == BF_ERR);
    BFStringReset(&string);
}

int main(void) {
    testCreateAndAssign();
    testDataConversions();
    testComparison();
    testInvalidUTF8Rejected();
    return 0;
}
