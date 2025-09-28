#include "BFPropertyList.h"
#include "BFCommon.h"

#include <assert.h>
#include <string.h>

static void testRoundTripDictionary(void) {
    BFPropertyListDictionary dictionary = BFPropertyListDictionaryCreate();

    BFString keyName   = BFStringCreateWithCString("name");
    BFString valueName = BFStringCreateWithCString("Thierry & Co <Box>");
    assert(BFPropertyListDictionarySetString(&dictionary, &keyName, &valueName) == BF_OK);

    BFString keyBuild = BFStringCreateWithCString("build");
    BFNumber buildNumber = BFNumberCreateWithInt64(42);
    assert(BFPropertyListDictionarySetNumber(&dictionary, &keyBuild, &buildNumber) == BF_OK);

    BFString keyEnabled = BFStringCreateWithCString("enabled");
    assert(BFPropertyListDictionarySetBoolean(&dictionary, &keyEnabled, 1) == BF_OK);

    BFString keyBlob = BFStringCreateWithCString("blob");
    const uint8_t blobBytes[] = {0x01U, 0xFFU, 0x7FU};
    BFData blobData = BFDataCreateWithBytes(blobBytes, sizeof(blobBytes));
    assert(BFPropertyListDictionarySetData(&dictionary, &keyBlob, &blobData) == BF_OK);

    BFData plistData = BFDataCreate(0U);
    assert(BFPropertyListDictionaryWriteToData(&dictionary, &plistData) == BF_OK);

    BFPropertyListDictionary parsed = BFPropertyListDictionaryCreate();
    assert(BFPropertyListDictionaryReadXML(&plistData, &parsed) == BF_OK);

    BFString extractedName = BFStringCreate();
    assert(BFPropertyListDictionaryGetString(&parsed, &keyName, &extractedName) == BF_OK);
    assert(BFStringIsEqual(&valueName, &extractedName) == 1);

    BFNumber extractedNumber;
    assert(BFPropertyListDictionaryGetNumber(&parsed, &keyBuild, &extractedNumber) == BF_OK);
    int comparison = 0;
    assert(BFNumberCompare(&buildNumber, &extractedNumber, &comparison) == BF_OK);
    assert(comparison == 0);

    int booleanValue = 0;
    assert(BFPropertyListDictionaryGetBoolean(&parsed, &keyEnabled, &booleanValue) == BF_OK);
    assert(booleanValue == 1);

    BFData extractedBlob = BFDataCreate(0U);
    assert(BFPropertyListDictionaryGetData(&parsed, &keyBlob, &extractedBlob) == BF_OK);
    assert(BFDataGetLength(&extractedBlob) == sizeof(blobBytes));
    assert(memcmp(BFDataGetBytes(&extractedBlob), blobBytes, sizeof(blobBytes)) == 0);

    BFDataReset(&extractedBlob);
    BFStringReset(&extractedName);
    BFPropertyListDictionaryReset(&parsed);
    BFDataReset(&plistData);
    BFDataReset(&blobData);
    BFPropertyListDictionaryReset(&dictionary);

    BFStringReset(&keyName);
    BFStringReset(&valueName);
    BFStringReset(&keyBuild);
    BFStringReset(&keyEnabled);
    BFStringReset(&keyBlob);
}

int main(void) {
    testRoundTripDictionary();
    return 0;
}
