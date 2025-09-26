#include "BFData.h"
#include "BFCommon.h"
#include "BFMemory.h"

#include <stdlib.h>
#include <string.h>

static void BFDataZero(BFData *data) {
    if (!data) {
        return;
    }
    data->bytes       = NULL;
    data->length      = 0U;
    data->capacity    = 0U;
    data->ownsMemory  = 0;
}

BFData BFDataCreateWithBytesNoCopy(uint8_t *bufferPointer, size_t bufferLength) {
    BFData data;
    BFDataZero(&data);
    data.bytes      = bufferPointer;
    data.length     = bufferLength;
    data.capacity   = bufferLength;
    data.ownsMemory = 0;
    return data;
}

BFData BFDataCreate(size_t initialCapacity) {
    BFData data = BFDataCreateWithBytesNoCopy(NULL, 0U);
    if (initialCapacity > 0U) {
        uint8_t *allocated = (uint8_t *)BFMemoryAllocate(initialCapacity);
        if (!allocated) {
            return data;
        }
        data.bytes      = allocated;
        data.length     = 0U;
        data.capacity   = initialCapacity;
        data.ownsMemory = 1;
    }
    return data;
}

BFData BFDataCreateWithBytes(const uint8_t *bufferPointer, size_t bufferLength) {
    BFData data = BFDataCreate(bufferLength);
    if (bufferLength > 0U && data.bytes) {
        (void)memcpy(data.bytes, bufferPointer, bufferLength);
        data.length = bufferLength;
    }
    return data;
}

void BFDataReset(BFData *data) {
    if (!data) {
        return;
    }
    if (data->ownsMemory && data->bytes) {
        BFMemoryRelease(data->bytes);
    }
    BFDataZero(data);
}

int BFDataEnsureCapacity(BFData *data, size_t requiredCapacity) {
    if (!data) {
        return BF_ERR;
    }
    if (requiredCapacity <= data->capacity) {
        return BF_OK;
    }
    size_t newCapacity = data->capacity == 0U ? requiredCapacity : data->capacity;
    while (newCapacity < requiredCapacity) {
        newCapacity = (newCapacity * 3U) / 2U;
        if (newCapacity < data->capacity) { // overflow
            newCapacity = requiredCapacity;
            break;
        }
    }
    uint8_t *newBuffer = (uint8_t *)BFMemoryAllocate(newCapacity);
    if (!newBuffer) {
        return BF_ERR;
    }
    if (data->bytes && data->length > 0U) {
        (void)memcpy(newBuffer, data->bytes, data->length);
    }
    if (data->ownsMemory && data->bytes) {
        BFMemoryRelease(data->bytes);
    }
    data->bytes    = newBuffer;
    data->capacity = newCapacity;
    data->ownsMemory = 1;
    return BF_OK;
}

int BFDataAppendBytes(BFData *data, const uint8_t *bytesPointer, size_t bytesLength) {
    if (!data) {
        return BF_ERR;
    }
    if (bytesLength == 0U) {
        return BF_OK;
    }
    if (BFDataEnsureCapacity(data, data->length + bytesLength) != BF_OK) {
        return BF_ERR;
    }
    if (data->bytes && bytesPointer) {
        (void)memcpy(data->bytes + data->length, bytesPointer, bytesLength);
    }
    data->length += bytesLength;
    return BF_OK;
}

int BFDataAppendByte(BFData *data, uint8_t byteValue) {
    return BFDataAppendBytes(data, &byteValue, 1U);
}

const uint8_t *BFDataGetBytes(const BFData *data) {
    return data ? data->bytes : NULL;
}

uint8_t *BFDataGetMutableBytes(BFData *data) {
    return data ? data->bytes : NULL;
}

size_t BFDataGetLength(const BFData *data) {
    return data ? data->length : 0U;
}

static int BFDataValidateRange(const BFData *data, size_t offset, size_t length) {
    if (!data) {
        return BF_ERR;
    }
    if (offset > data->length) {
        return BF_ERR;
    }
    if (length > data->length - offset) {
        return BF_ERR;
    }
    return BF_OK;
}

int BFDataGetBytesInRange(const BFData *data, size_t offset, size_t length, const uint8_t **outPointer) {
    if (BFDataValidateRange(data, offset, length) != BF_OK || !outPointer) {
        return BF_ERR;
    }
    *outPointer = data->bytes ? data->bytes + offset : NULL;
    return BF_OK;
}

int BFDataCopyBytesInRange(const BFData *data, size_t offset, size_t length, uint8_t *destination) {
    if (BFDataValidateRange(data, offset, length) != BF_OK || !destination) {
        return BF_ERR;
    }
    if (length == 0U) {
        return BF_OK;
    }
    (void)memcpy(destination, data->bytes + offset, length);
    return BF_OK;
}

int BFDataSetLength(BFData *data, size_t newLength) {
    if (!data) {
        return BF_ERR;
    }
    if (newLength > data->capacity) {
        if (BFDataEnsureCapacity(data, newLength) != BF_OK) {
            return BF_ERR;
        }
    }
    data->length = newLength;
    return BF_OK;
}

char *BFDataCopyBytesAsCString(const BFData *data) {
    if (!data) {
        return NULL;
    }
    size_t  length = data->length;
    char   *copy   = (char *)BFMemoryAllocate(length + 1U);
    if (!copy) {
        return NULL;
    }
    if (length > 0U && data->bytes) {
        (void)memcpy(copy, data->bytes, length);
    }
    copy[length] = '\0';
    return copy;
}

static const char base64Alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static char *BFDataEncodeBase64(const uint8_t *input, size_t length) {
    if (length == 0U) {
        char *empty = (char *)BFMemoryAllocate(1U);
        if (empty) {
            empty[0] = '\0';
        }
        return empty;
    }
    size_t outputLength = ((length + 2U) / 3U) * 4U;
    char  *output       = (char *)BFMemoryAllocate(outputLength + 1U);
    if (!output) {
        return NULL;
    }
    size_t inputIndex  = 0U;
    size_t outputIndex = 0U;
    while (inputIndex < length) {
        size_t   remaining = length - inputIndex;
        uint32_t octetA    = input[inputIndex++];
        uint32_t octetB    = remaining > 1U ? input[inputIndex++] : 0U;
        uint32_t octetC    = remaining > 2U ? input[inputIndex++] : 0U;
        uint32_t triple    = (octetA << 16U) | (octetB << 8U) | octetC;
        output[outputIndex++] = base64Alphabet[(triple >> 18U) & 0x3FU];
        output[outputIndex++] = base64Alphabet[(triple >> 12U) & 0x3FU];
        output[outputIndex++] = (remaining > 1U) ? base64Alphabet[(triple >> 6U) & 0x3FU] : '=';
        output[outputIndex++] = (remaining > 2U) ? base64Alphabet[triple & 0x3FU] : '=';
    }
    output[outputLength] = '\0';
    return output;
}

char *BFDataCopyBase64EncodedString(const BFData *data) {
    if (!data) {
        return NULL;
    }
    return BFDataEncodeBase64(data->bytes, data->length);
}

static uint8_t base64DecodeTable[256];
static int     base64TableInitialized = 0;

static void BFDataInitializeBase64Table(void) {
    if (base64TableInitialized) {
        return;
    }
    memset(base64DecodeTable, 0xFF, sizeof(base64DecodeTable));
    for (uint8_t index = 0U; index < 64U; ++index) {
        base64DecodeTable[(unsigned char)base64Alphabet[index]] = index;
    }
    base64DecodeTable[(unsigned char)'='] = 0U;
    base64TableInitialized                 = 1;
}

static int BFDataDecodeBase64(const char *inputCString, uint8_t **outBytes, size_t *outLength) {
    if (!inputCString || !outBytes || !outLength) {
        return BF_ERR;
    }
    BFDataInitializeBase64Table();
    size_t inputLength = strlen(inputCString);
    if (inputLength % 4U != 0U) {
        return BF_ERR;
    }
    size_t padding = 0U;
    if (inputLength >= 2U) {
        if (inputCString[inputLength - 1U] == '=') {
            padding++;
        }
        if (inputCString[inputLength - 2U] == '=') {
            padding++;
        }
    }
    size_t outputLength = ((inputLength / 4U) * 3U) - padding;
    uint8_t *output     = (uint8_t *)BFMemoryAllocate(outputLength);
    if (!output) {
        return BF_ERR;
    }
    size_t inputIndex  = 0U;
    size_t outputIndex = 0U;
    while (inputIndex < inputLength) {
        unsigned char charA = (unsigned char)inputCString[inputIndex++];
        unsigned char charB = (unsigned char)inputCString[inputIndex++];
        unsigned char charC = (unsigned char)inputCString[inputIndex++];
        unsigned char charD = (unsigned char)inputCString[inputIndex++];
        if (base64DecodeTable[charA] == 0xFF || base64DecodeTable[charB] == 0xFF ||
            (charC != '=' && base64DecodeTable[charC] == 0xFF) ||
            (charD != '=' && base64DecodeTable[charD] == 0xFF)) {
            BFMemoryRelease(output);
            return BF_ERR;
        }
        uint32_t sextetA = base64DecodeTable[charA];
        uint32_t sextetB = base64DecodeTable[charB];
        uint32_t sextetC = (charC == '=') ? 0U : base64DecodeTable[charC];
        uint32_t sextetD = (charD == '=') ? 0U : base64DecodeTable[charD];
        uint32_t triple   = (sextetA << 18U) | (sextetB << 12U) | (sextetC << 6U) | sextetD;
        if (outputIndex < outputLength) {
            output[outputIndex++] = (uint8_t)((triple >> 16U) & 0xFFU);
        }
        if (charC != '=' && outputIndex < outputLength) {
            output[outputIndex++] = (uint8_t)((triple >> 8U) & 0xFFU);
        }
        if (charD != '=' && outputIndex < outputLength) {
            output[outputIndex++] = (uint8_t)(triple & 0xFFU);
        }
    }
    *outBytes  = output;
    *outLength = outputLength;
    return BF_OK;
}

int BFDataSetFromBase64CString(BFData *data, const char *base64CString) {
    if (!data) {
        return BF_ERR;
    }
    BFDataReset(data);
    if (!base64CString || base64CString[0] == '\0') {
        return BF_OK;
    }
    uint8_t *decodedBytes  = NULL;
    size_t   decodedLength = 0U;
    if (BFDataDecodeBase64(base64CString, &decodedBytes, &decodedLength) != BF_OK) {
        return BF_ERR;
    }
    data->bytes      = decodedBytes;
    data->length     = decodedLength;
    data->capacity   = decodedLength;
    data->ownsMemory = 1;
    return BF_OK;
}
