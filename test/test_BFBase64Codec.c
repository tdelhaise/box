#include "BFBase64Codec.h"
#include "BFCommon.h"

#include <assert.h>
#include <string.h>

static void testEncodeDecodeData(void) {
    BFData   data   = BFDataCreateWithBytes((const uint8_t *)"Box", 3U);
    BFString string = BFStringCreate();
    assert(BFBase64CodecEncodeDataToString(&data, &string) == BF_OK);
    assert(strcmp(BFStringGetCString(&string), "Qm94") == 0);

    BFData roundtrip = BFDataCreate(0U);
    assert(BFBase64CodecDecodeStringToData(&string, &roundtrip) == BF_OK);
    assert(BFDataGetLength(&roundtrip) == 3U);
    assert(memcmp(BFDataGetBytes(&roundtrip), "Box", 3U) == 0);

    BFStringReset(&string);
    BFDataReset(&data);
    BFDataReset(&roundtrip);
}

static void testEncodeDecodeString(void) {
    BFString plain  = BFStringCreateWithCString("hello world");
    BFString encoded = BFStringCreate();
    assert(BFBase64CodecEncodeStringToString(&plain, &encoded) == BF_OK);
    assert(strcmp(BFStringGetCString(&encoded), "aGVsbG8gd29ybGQ=") == 0);

    BFString decoded = BFStringCreate();
    assert(BFBase64CodecDecodeStringToString(&encoded, &decoded) == BF_OK);
    assert(BFStringIsEqual(&plain, &decoded) == 1);

    BFStringReset(&plain);
    BFStringReset(&encoded);
    BFStringReset(&decoded);
}

int main(void) {
    testEncodeDecodeData();
    testEncodeDecodeString();
    return 0;
}
