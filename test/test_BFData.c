#include "BFCommon.h"
#include "BFData.h"
#include "BFMemory.h"

#include <assert.h>
#include <stdint.h>
#include <string.h>

static void testCreateAndAppend(void) {
    BFData data = BFDataCreate(0U);
    assert(BFDataGetLength(&data) == 0U);

    const uint8_t sample[] = {1U, 2U, 3U, 4U};
    assert(BFDataAppendBytes(&data, sample, sizeof(sample)) == BF_OK);
    assert(BFDataGetLength(&data) == sizeof(sample));

    const uint8_t *rangePointer = NULL;
    assert(BFDataGetBytesInRange(&data, 1U, 2U, &rangePointer) == BF_OK);
    assert(rangePointer[0] == 2U);
    assert(rangePointer[1] == 3U);

    assert(BFDataAppendByte(&data, 5U) == BF_OK);
    assert(BFDataGetLength(&data) == 5U);

    BFDataReset(&data);
}

static void testBase64RoundTrip(void) {
    const char  *plainText = "Man"; // classic Base64 fixture
    BFData        original = BFDataCreateWithBytes((const uint8_t *)plainText, strlen(plainText));
    char         *encoded  = BFDataCopyBase64EncodedString(&original);
    assert(encoded != NULL);
    assert(strcmp(encoded, "TWFu") == 0);

    BFData decoded = BFDataCreate(0U);
    assert(BFDataSetFromBase64CString(&decoded, encoded) == BF_OK);
    assert(BFDataGetLength(&decoded) == strlen(plainText));
    assert(memcmp(BFDataGetBytes(&decoded), plainText, strlen(plainText)) == 0);

    BFMemoryRelease(encoded);
    BFDataReset(&decoded);
    BFDataReset(&original);
}

static void testSetLengthAndCopy(void) {
    BFData data = BFDataCreate(2U);
    assert(BFDataSetLength(&data, 2U) == BF_OK);
    uint8_t *mutableBytes = BFDataGetMutableBytes(&data);
    mutableBytes[0]       = 0xAAU;
    mutableBytes[1]       = 0xBBU;

    assert(BFDataSetLength(&data, 4U) == BF_OK);
    mutableBytes = BFDataGetMutableBytes(&data);
    mutableBytes[2] = 0xCCU;
    mutableBytes[3] = 0xDDU;

    uint8_t copyBuffer[4] = {0};
    assert(BFDataCopyBytesInRange(&data, 0U, 4U, copyBuffer) == BF_OK);
    assert(copyBuffer[0] == 0xAAU && copyBuffer[3] == 0xDDU);

    BFDataReset(&data);
}

int main(void) {
    testCreateAndAppend();
    testBase64RoundTrip();
    testSetLengthAndCopy();
    return 0;
}
