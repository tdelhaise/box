#include "BFNumber.h"
#include "BFString.h"
#include "BFCommon.h"

#include <assert.h>

static void testCreationAndConversion(void) {
    BFNumber signedNumber   = BFNumberCreateWithInt64(-42);
    BFNumber unsignedNumber = BFNumberCreateWithUInt64(42U);
    BFNumber floatNumber    = BFNumberCreateWithDouble(3.14);

    int64_t  intValue  = 0;
    uint64_t uintValue = 0U;
    double   doubleValue = 0.0;

    assert(BFNumberGetInt64(&signedNumber, &intValue) == BF_OK);
    assert(intValue == -42);

    assert(BFNumberGetUInt64(&unsignedNumber, &uintValue) == BF_OK);
    assert(uintValue == 42U);

    assert(BFNumberGetDouble(&floatNumber, &doubleValue) == BF_OK);
    assert(doubleValue > 3.13 && doubleValue < 3.15);
}

static void testComparison(void) {
    BFNumber negative = BFNumberCreateWithInt64(-1);
    BFNumber positiveUnsigned = BFNumberCreateWithUInt64(1U);
    int      comparison = 0;

    assert(BFNumberCompare(&negative, &positiveUnsigned, &comparison) == BF_OK);
    assert(comparison < 0);

    BFNumber bigUnsigned = BFNumberCreateWithUInt64(1000U);
    BFNumber bigSigned   = BFNumberCreateWithInt64(999);
    assert(BFNumberCompare(&bigUnsigned, &bigSigned, &comparison) == BF_OK);
    assert(comparison > 0);

    BFNumber floatNumber = BFNumberCreateWithDouble(10.5);
    BFNumber intNumber   = BFNumberCreateWithInt64(10);
    assert(BFNumberCompare(&floatNumber, &intNumber, &comparison) == BF_OK);
    assert(comparison > 0);
}

static void testFormatAndParse(void) {
    BFNumber signedNumber = BFNumberCreateWithInt64(12345);
    BFString formatted    = BFStringCreate();
    BFString expected     = BFStringCreateWithCString("12345");
    assert(BFNumberFormatDecimal(&signedNumber, &formatted) == BF_OK);
    assert(BFStringIsEqual(&formatted, &expected) == 1);
    BFStringReset(&formatted);
    BFStringReset(&expected);

    BFNumber parsedNumber;
    assert(BFNumberParseDecimalCString(&parsedNumber, "-9876") == BF_OK);
    int64_t intValue = 0;
    assert(BFNumberGetInt64(&parsedNumber, &intValue) == BF_OK);
    assert(intValue == -9876);

    BFNumber floatNumber;
    assert(BFNumberParseDecimalCString(&floatNumber, "2.5") == BF_OK);
    double doubleValue = 0.0;
    assert(BFNumberGetDouble(&floatNumber, &doubleValue) == BF_OK);
    assert(doubleValue > 2.49 && doubleValue < 2.51);
}

int main(void) {
    testCreationAndConversion();
    testComparison();
    testFormatAndParse();
    return 0;
}
