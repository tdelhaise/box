#include "BFBase64Codec.h"

#include "BFCommon.h"
#include "BFData.h"
#include "BFMemory.h"

int BFBase64CodecEncodeDataToString(const BFData *data, BFString *outString) {
    if (!data || !outString) {
        return BF_ERR;
    }
    char *encodedCString = BFDataCopyBase64EncodedString(data);
    if (!encodedCString) {
        return BF_ERR;
    }
    int result = BFStringSetFromCString(outString, encodedCString);
    BFMemoryRelease(encodedCString);
    return result;
}

int BFBase64CodecEncodeStringToString(const BFString *plainString, BFString *outString) {
    if (!plainString || !outString) {
        return BF_ERR;
    }
    BFData intermediate = BFDataCreateWithBytes((const uint8_t *)BFStringGetCString(plainString), BFStringGetLength(plainString));
    int     status       = BFBase64CodecEncodeDataToString(&intermediate, outString);
    BFDataReset(&intermediate);
    return status;
}

int BFBase64CodecDecodeStringToData(const BFString *encodedString, BFData *outData) {
    if (!encodedString || !outData) {
        return BF_ERR;
    }
    return BFDataSetFromBase64CString(outData, BFStringGetCString(encodedString));
}

int BFBase64CodecDecodeStringToString(const BFString *encodedString, BFString *outString) {
    if (!encodedString || !outString) {
        return BF_ERR;
    }
    BFData decoded = BFDataCreate(0U);
    if (BFBase64CodecDecodeStringToData(encodedString, &decoded) != BF_OK) {
        BFDataReset(&decoded);
        return BF_ERR;
    }
    int status = BFStringSetFromData(outString, &decoded);
    BFDataReset(&decoded);
    return status;
}
