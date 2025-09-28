#include "BFString.h"

#include "BFCommon.h"
#include "BFMemory.h"

#include <limits.h>
#include <stdint.h>
#include <string.h>

static int BFStringEnsureCapacity(BFString *string, size_t requiredLength);
static int BFStringValidateUTF8(const char *charactersPointer, size_t charactersLength);
static int BFStringContainsEmbeddedNull(const char *charactersPointer, size_t charactersLength);

BFString BFStringCreate(void) {
    BFString string;
    string.characters = NULL;
    string.length     = 0U;
    string.capacity   = 0U;
    return string;
}

BFString BFStringCreateWithCString(const char *cString) {
    BFString string = BFStringCreate();
    if (BFStringSetFromCString(&string, cString) != BF_OK) {
        BFStringReset(&string);
    }
    return string;
}

BFString BFStringCreateWithUTF8Bytes(const char *charactersPointer, size_t charactersLength) {
    BFString string = BFStringCreate();
    if (BFStringSetFromUTF8Bytes(&string, charactersPointer, charactersLength) != BF_OK) {
        BFStringReset(&string);
    }
    return string;
}

BFString BFStringCreateWithData(const BFData *data) {
    BFString string = BFStringCreate();
    if (BFStringSetFromData(&string, data) != BF_OK) {
        BFStringReset(&string);
    }
    return string;
}

void BFStringReset(BFString *string) {
    if (!string) {
        return;
    }
    if (string->characters) {
        memset(string->characters, 0, string->capacity);
        BFMemoryRelease(string->characters);
    }
    string->characters = NULL;
    string->length     = 0U;
    string->capacity   = 0U;
}

int BFStringSetFromCString(BFString *string, const char *cString) {
    if (!string || !cString) {
        return BF_ERR;
    }
    size_t charactersLength = strlen(cString);
    return BFStringSetFromUTF8Bytes(string, cString, charactersLength);
}

int BFStringSetFromUTF8Bytes(BFString *string, const char *charactersPointer, size_t charactersLength) {
    if (!string || (!charactersPointer && charactersLength != 0U)) {
        return BF_ERR;
    }
    if (charactersLength == 0U) {
        BFStringReset(string);
        return BF_OK;
    }
    if (BFStringValidateUTF8(charactersPointer, charactersLength) != BF_OK) {
        return BF_ERR;
    }
    if (BFStringContainsEmbeddedNull(charactersPointer, charactersLength) != BF_OK) {
        return BF_ERR;
    }
    if (BFStringEnsureCapacity(string, charactersLength) != BF_OK) {
        return BF_ERR;
    }
    memcpy(string->characters, charactersPointer, charactersLength);
    string->length                 = charactersLength;
    string->characters[string->length] = '\0';
    return BF_OK;
}

int BFStringSetFromData(BFString *string, const BFData *data) {
    if (!data) {
        return BF_ERR;
    }
    const uint8_t *bytesPointer = BFDataGetBytes(data);
    size_t         bytesLength  = BFDataGetLength(data);
    return BFStringSetFromUTF8Bytes(string, (const char *)bytesPointer, bytesLength);
}

int BFStringCopy(BFString *destination, const BFString *source) {
    if (!destination || !source) {
        return BF_ERR;
    }
    if (source->length == 0U) {
        BFStringReset(destination);
        return BF_OK;
    }
    return BFStringSetFromUTF8Bytes(destination, source->characters, source->length);
}

const char *BFStringGetCString(const BFString *string) {
    if (!string || !string->characters) {
        return "";
    }
    return string->characters;
}

size_t BFStringGetLength(const BFString *string) {
    if (!string) {
        return 0U;
    }
    return string->length;
}

int BFStringCompare(const BFString *leftString, const BFString *rightString, int *comparisonResult) {
    if (!leftString || !rightString || !comparisonResult) {
        return BF_ERR;
    }
    const size_t leftLength  = leftString->length;
    const size_t rightLength = rightString->length;
    const size_t minLength   = (leftLength < rightLength) ? leftLength : rightLength;
    int          diff        = 0;
    if (minLength > 0U) {
        diff = memcmp(leftString->characters ? leftString->characters : "", rightString->characters ? rightString->characters : "", minLength);
    }
    if (diff == 0) {
        if (leftLength < rightLength) {
            diff = -1;
        } else if (leftLength > rightLength) {
            diff = 1;
        }
    }
    if (diff < 0) {
        *comparisonResult = -1;
    } else if (diff > 0) {
        *comparisonResult = 1;
    } else {
        *comparisonResult = 0;
    }
    return BF_OK;
}

int BFStringIsEqual(const BFString *leftString, const BFString *rightString) {
    int comparison = 0;
    if (BFStringCompare(leftString, rightString, &comparison) != BF_OK) {
        return 0;
    }
    return comparison == 0 ? 1 : 0;
}

int BFStringAppendCString(BFString *string, const char *cString) {
    if (!string || !cString) {
        return BF_ERR;
    }
    size_t charactersLength = strlen(cString);
    return BFStringAppendUTF8Bytes(string, cString, charactersLength);
}

int BFStringAppendString(BFString *string, const BFString *otherString) {
    if (!string || !otherString) {
        return BF_ERR;
    }
    return BFStringAppendUTF8Bytes(string, otherString->characters, otherString->length);
}

int BFStringAppendUTF8Bytes(BFString *string, const char *charactersPointer, size_t charactersLength) {
    if (!string || (!charactersPointer && charactersLength != 0U)) {
        return BF_ERR;
    }
    if (charactersLength == 0U) {
        return BF_OK;
    }
    if (BFStringValidateUTF8(charactersPointer, charactersLength) != BF_OK) {
        return BF_ERR;
    }
    if (BFStringContainsEmbeddedNull(charactersPointer, charactersLength) != BF_OK) {
        return BF_ERR;
    }
    size_t newLength = string->length + charactersLength;
    if (newLength < string->length) {
        return BF_ERR;
    }
    if (BFStringEnsureCapacity(string, newLength) != BF_OK) {
        return BF_ERR;
    }
    memcpy(string->characters + string->length, charactersPointer, charactersLength);
    string->length = newLength;
    string->characters[string->length] = '\0';
    return BF_OK;
}

int BFStringAppendData(BFString *string, const BFData *data) {
    if (!string || !data) {
        return BF_ERR;
    }
    const uint8_t *bytesPointer = BFDataGetBytes(data);
    size_t         bytesLength  = BFDataGetLength(data);
    return BFStringAppendUTF8Bytes(string, (const char *)bytesPointer, bytesLength);
}

int BFStringCopyToData(const BFString *string, BFData *outData) {
    if (!string || !outData) {
        return BF_ERR;
    }
    if (BFDataEnsureCapacity(outData, string->length) != BF_OK) {
        return BF_ERR;
    }
    if (string->length > 0U && string->characters) {
        memcpy(BFDataGetMutableBytes(outData), string->characters, string->length);
    }
    (void)BFDataSetLength(outData, string->length);
    return BF_OK;
}

static int BFStringEnsureCapacity(BFString *string, size_t requiredLength) {
    if (!string) {
        return BF_ERR;
    }
    size_t requiredCapacity = requiredLength + 1U;
    if (requiredCapacity <= string->capacity && string->characters != NULL) {
        return BF_OK;
    }
    size_t newCapacity = string->capacity;
    if (newCapacity == 0U) {
        newCapacity = requiredCapacity;
    }
    while (newCapacity < requiredCapacity) {
        if (newCapacity > SIZE_MAX / 2U) {
            newCapacity = requiredCapacity;
            break;
        }
        newCapacity *= 2U;
    }
    char *newCharacters = (char *)BFMemoryAllocate(newCapacity);
    if (!newCharacters) {
        return BF_ERR;
    }
    if (string->characters && string->length > 0U) {
        memcpy(newCharacters, string->characters, string->length);
    }
    newCharacters[string->length] = '\0';
    if (string->characters) {
        memset(string->characters, 0, string->capacity);
        BFMemoryRelease(string->characters);
    }
    string->characters = newCharacters;
    string->capacity   = newCapacity;
    return BF_OK;
}

static int BFStringValidateUTF8(const char *charactersPointer, size_t charactersLength) {
    if (!charactersPointer && charactersLength != 0U) {
        return BF_ERR;
    }
    size_t index = 0U;
    while (index < charactersLength) {
        unsigned char byte = (unsigned char)charactersPointer[index];
        if (byte <= 0x7FU) {
            index += 1U;
            continue;
        }
        size_t expectedAdditionalBytes = 0U;
        if ((byte & 0xE0U) == 0xC0U) {
            expectedAdditionalBytes = 1U;
            if ((byte & 0x1EU) == 0U) {
                return BF_ERR;
            }
        } else if ((byte & 0xF0U) == 0xE0U) {
            expectedAdditionalBytes = 2U;
        } else if ((byte & 0xF8U) == 0xF0U) {
            expectedAdditionalBytes = 3U;
            if (byte > 0xF4U) {
                return BF_ERR;
            }
        } else {
            return BF_ERR;
        }
        if (index + expectedAdditionalBytes >= charactersLength) {
            return BF_ERR;
        }
        for (size_t offset = 1U; offset <= expectedAdditionalBytes; ++offset) {
            unsigned char continuation = (unsigned char)charactersPointer[index + offset];
            if ((continuation & 0xC0U) != 0x80U) {
                return BF_ERR;
            }
        }
        index += expectedAdditionalBytes + 1U;
    }
    return BF_OK;
}

static int BFStringContainsEmbeddedNull(const char *charactersPointer, size_t charactersLength) {
    if (!charactersPointer && charactersLength != 0U) {
        return BF_ERR;
    }
    for (size_t index = 0U; index < charactersLength; ++index) {
        if (charactersPointer[index] == '\0') {
            return BF_ERR;
        }
    }
    return BF_OK;
}
