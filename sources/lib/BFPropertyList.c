#include "BFPropertyList.h"

#include "BFCommon.h"
#include "BFMemory.h"

#include <ctype.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

static void BFPropertyListValueReset(BFPropertyListValue *value);
static int  BFPropertyListValueSetString(BFPropertyListValue *value, const BFString *stringValue);
static int  BFPropertyListValueSetNumber(BFPropertyListValue *value, const BFNumber *numberValue);
static int  BFPropertyListValueSetData(BFPropertyListValue *value, const BFData *dataValue);
static int  BFPropertyListValueSetBoolean(BFPropertyListValue *value, int booleanValue);
static int  BFPropertyListEnsureCapacity(BFPropertyListDictionary *dictionary, size_t requiredCount);
static BFPropertyListDictionaryEntry *BFPropertyListDictionaryEnsureEntry(BFPropertyListDictionary *dictionary, const BFString *key);
static BFPropertyListDictionaryEntry *BFPropertyListDictionaryFindEntry(BFPropertyListDictionary *dictionary, const BFString *key);
static const BFPropertyListDictionaryEntry *BFPropertyListDictionaryFindEntryConst(const BFPropertyListDictionary *dictionary, const BFString *key);
static int  BFPropertyListAppendEscaped(const BFString *source, BFString *destination);
static int  BFPropertyListDecodeEscaped(const char *charactersPointer, size_t charactersLength, BFString *destination);
static void BFPropertyListSkipWhitespace(const char **cursorPointer);
static void BFPropertyListTrimWhitespace(const char **startPointer, const char **endPointer);
static int  BFPropertyListDecodeBase64Segment(const char *charactersPointer, size_t charactersLength, BFData *outData);

BFPropertyListDictionary BFPropertyListDictionaryCreate(void) {
    BFPropertyListDictionary dictionary;
    dictionary.entries  = NULL;
    dictionary.count    = 0U;
    dictionary.capacity = 0U;
    return dictionary;
}

void BFPropertyListDictionaryReset(BFPropertyListDictionary *dictionary) {
    if (!dictionary) {
        return;
    }
    for (size_t index = 0U; index < dictionary->count; ++index) {
        BFStringReset(&dictionary->entries[index].key);
        BFPropertyListValueReset(&dictionary->entries[index].value);
    }
    if (dictionary->entries) {
        BFMemoryRelease(dictionary->entries);
    }
    dictionary->entries  = NULL;
    dictionary->count    = 0U;
    dictionary->capacity = 0U;
}

size_t BFPropertyListDictionaryGetCount(const BFPropertyListDictionary *dictionary) {
    return dictionary ? dictionary->count : 0U;
}

const BFPropertyListDictionaryEntry *BFPropertyListDictionaryGetEntryAtIndex(const BFPropertyListDictionary *dictionary, size_t index) {
    if (!dictionary || index >= dictionary->count) {
        return NULL;
    }
    return &dictionary->entries[index];
}

int BFPropertyListDictionarySetString(BFPropertyListDictionary *dictionary, const BFString *key, const BFString *value) {
    if (!dictionary || !key || !value) {
        return BF_ERR;
    }
    BFPropertyListDictionaryEntry *entry = BFPropertyListDictionaryEnsureEntry(dictionary, key);
    if (!entry) {
        return BF_ERR;
    }
    if (BFPropertyListValueSetString(&entry->value, value) != BF_OK) {
        return BF_ERR;
    }
    return BF_OK;
}

int BFPropertyListDictionarySetNumber(BFPropertyListDictionary *dictionary, const BFString *key, const BFNumber *value) {
    if (!dictionary || !key || !value) {
        return BF_ERR;
    }
    BFPropertyListDictionaryEntry *entry = BFPropertyListDictionaryEnsureEntry(dictionary, key);
    if (!entry) {
        return BF_ERR;
    }
    if (BFPropertyListValueSetNumber(&entry->value, value) != BF_OK) {
        return BF_ERR;
    }
    return BF_OK;
}

int BFPropertyListDictionarySetData(BFPropertyListDictionary *dictionary, const BFString *key, const BFData *value) {
    if (!dictionary || !key || !value) {
        return BF_ERR;
    }
    BFPropertyListDictionaryEntry *entry = BFPropertyListDictionaryEnsureEntry(dictionary, key);
    if (!entry) {
        return BF_ERR;
    }
    if (BFPropertyListValueSetData(&entry->value, value) != BF_OK) {
        return BF_ERR;
    }
    return BF_OK;
}

int BFPropertyListDictionarySetBoolean(BFPropertyListDictionary *dictionary, const BFString *key, int booleanValue) {
    if (!dictionary || !key) {
        return BF_ERR;
    }
    BFPropertyListDictionaryEntry *entry = BFPropertyListDictionaryEnsureEntry(dictionary, key);
    if (!entry) {
        return BF_ERR;
    }
    if (BFPropertyListValueSetBoolean(&entry->value, booleanValue) != BF_OK) {
        return BF_ERR;
    }
    return BF_OK;
}

int BFPropertyListDictionaryGetString(const BFPropertyListDictionary *dictionary, const BFString *key, BFString *outString) {
    if (!dictionary || !key || !outString) {
        return BF_ERR;
    }
    const BFPropertyListDictionaryEntry *entry = BFPropertyListDictionaryFindEntryConst(dictionary, key);
    if (!entry || entry->value.type != BFPropertyListValueTypeString) {
        return BF_ERR;
    }
    return BFStringCopy(outString, &entry->value.value.stringValue);
}

int BFPropertyListDictionaryGetNumber(const BFPropertyListDictionary *dictionary, const BFString *key, BFNumber *outNumber) {
    if (!dictionary || !key || !outNumber) {
        return BF_ERR;
    }
    const BFPropertyListDictionaryEntry *entry = BFPropertyListDictionaryFindEntryConst(dictionary, key);
    if (!entry || entry->value.type != BFPropertyListValueTypeNumber) {
        return BF_ERR;
    }
    *outNumber = entry->value.value.numberValue;
    return BF_OK;
}

int BFPropertyListDictionaryGetData(const BFPropertyListDictionary *dictionary, const BFString *key, BFData *outData) {
    if (!dictionary || !key || !outData) {
        return BF_ERR;
    }
    const BFPropertyListDictionaryEntry *entry = BFPropertyListDictionaryFindEntryConst(dictionary, key);
    if (!entry || entry->value.type != BFPropertyListValueTypeData) {
        return BF_ERR;
    }
    BFDataReset(outData);
    size_t dataLength = BFDataGetLength(&entry->value.value.dataValue);
    if (BFDataEnsureCapacity(outData, dataLength) != BF_OK) {
        return BF_ERR;
    }
    if (dataLength > 0U) {
        memcpy(BFDataGetMutableBytes(outData), BFDataGetBytes(&entry->value.value.dataValue), dataLength);
    }
    BFDataSetLength(outData, dataLength);
    return BF_OK;
}

int BFPropertyListDictionaryGetBoolean(const BFPropertyListDictionary *dictionary, const BFString *key, int *outBoolean) {
    if (!dictionary || !key || !outBoolean) {
        return BF_ERR;
    }
    const BFPropertyListDictionaryEntry *entry = BFPropertyListDictionaryFindEntryConst(dictionary, key);
    if (!entry || entry->value.type != BFPropertyListValueTypeBoolean) {
        return BF_ERR;
    }
    *outBoolean = entry->value.value.booleanValue ? 1 : 0;
    return BF_OK;
}

int BFPropertyListDictionaryWriteXML(const BFPropertyListDictionary *dictionary, BFString *outString) {
    if (!dictionary || !outString) {
        return BF_ERR;
    }
    BFString builder = BFStringCreate();
    if (BFStringAppendCString(&builder, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n") != BF_OK) {
        BFStringReset(&builder);
        return BF_ERR;
    }
    if (BFStringAppendCString(&builder, "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n") != BF_OK) {
        BFStringReset(&builder);
        return BF_ERR;
    }
    if (BFStringAppendCString(&builder, "<plist version=\"1.0\">\n<dict>\n") != BF_OK) {
        BFStringReset(&builder);
        return BF_ERR;
    }

    for (size_t index = 0U; index < dictionary->count; ++index) {
        const BFPropertyListDictionaryEntry *entry = &dictionary->entries[index];
        BFString escapedKey = BFStringCreate();
        if (BFPropertyListAppendEscaped(&entry->key, &escapedKey) != BF_OK) {
            BFStringReset(&escapedKey);
            BFStringReset(&builder);
            return BF_ERR;
        }
        if (BFStringAppendCString(&builder, "    <key>") != BF_OK || BFStringAppendString(&builder, &escapedKey) != BF_OK || BFStringAppendCString(&builder, "</key>\n") != BF_OK) {
            BFStringReset(&escapedKey);
            BFStringReset(&builder);
            return BF_ERR;
        }
        BFStringReset(&escapedKey);

        switch (entry->value.type) {
            case BFPropertyListValueTypeString: {
                BFString escapedValue = BFStringCreate();
                if (BFPropertyListAppendEscaped(&entry->value.value.stringValue, &escapedValue) != BF_OK) {
                    BFStringReset(&escapedValue);
                    BFStringReset(&builder);
                    return BF_ERR;
                }
                if (BFStringAppendCString(&builder, "    <string>") != BF_OK || BFStringAppendString(&builder, &escapedValue) != BF_OK || BFStringAppendCString(&builder, "</string>\n") != BF_OK) {
                    BFStringReset(&escapedValue);
                    BFStringReset(&builder);
                    return BF_ERR;
                }
                BFStringReset(&escapedValue);
                break;
            }
            case BFPropertyListValueTypeNumber: {
                BFString numberBuffer = BFStringCreate();
                if (BFNumberFormatDecimal(&entry->value.value.numberValue, &numberBuffer) != BF_OK) {
                    BFStringReset(&numberBuffer);
                    BFStringReset(&builder);
                    return BF_ERR;
                }
                if (BFNumberGetType(&entry->value.value.numberValue) == BFNumberTypeFloating) {
                    if (BFStringAppendCString(&builder, "    <real>") != BF_OK || BFStringAppendString(&builder, &numberBuffer) != BF_OK || BFStringAppendCString(&builder, "</real>\n") != BF_OK) {
                        BFStringReset(&numberBuffer);
                        BFStringReset(&builder);
                        return BF_ERR;
                    }
                } else {
                    if (BFStringAppendCString(&builder, "    <integer>") != BF_OK || BFStringAppendString(&builder, &numberBuffer) != BF_OK || BFStringAppendCString(&builder, "</integer>\n") != BF_OK) {
                        BFStringReset(&numberBuffer);
                        BFStringReset(&builder);
                        return BF_ERR;
                    }
                }
                BFStringReset(&numberBuffer);
                break;
            }
            case BFPropertyListValueTypeData: {
                BFString base64String = BFStringCreate();
                if (BFBase64CodecEncodeDataToString(&entry->value.value.dataValue, &base64String) != BF_OK) {
                    BFStringReset(&base64String);
                    BFStringReset(&builder);
                    return BF_ERR;
                }
                if (BFStringAppendCString(&builder, "    <data>") != BF_OK || BFStringAppendString(&builder, &base64String) != BF_OK || BFStringAppendCString(&builder, "</data>\n") != BF_OK) {
                    BFStringReset(&base64String);
                    BFStringReset(&builder);
                    return BF_ERR;
                }
                BFStringReset(&base64String);
                break;
            }
            case BFPropertyListValueTypeBoolean: {
                if (entry->value.value.booleanValue) {
                    if (BFStringAppendCString(&builder, "    <true/>\n") != BF_OK) {
                        BFStringReset(&builder);
                        return BF_ERR;
                    }
                } else {
                    if (BFStringAppendCString(&builder, "    <false/>\n") != BF_OK) {
                        BFStringReset(&builder);
                        return BF_ERR;
                    }
                }
                break;
            }
            default:
                BFStringReset(&builder);
                return BF_ERR;
        }
    }

    if (BFStringAppendCString(&builder, "</dict>\n</plist>\n") != BF_OK) {
        BFStringReset(&builder);
        return BF_ERR;
    }

    BFStringReset(outString);
    *outString = builder;
    return BF_OK;
}

int BFPropertyListDictionaryWriteToData(const BFPropertyListDictionary *dictionary, BFData *outData) {
    if (!dictionary || !outData) {
        return BF_ERR;
    }
    BFString xmlString = BFStringCreate();
    if (BFPropertyListDictionaryWriteXML(dictionary, &xmlString) != BF_OK) {
        BFStringReset(&xmlString);
        return BF_ERR;
    }
    int result = BFStringCopyToData(&xmlString, outData);
    BFStringReset(&xmlString);
    return result;
}

int BFPropertyListDictionaryReadXML(const BFData *propertyListData, BFPropertyListDictionary *outDictionary) {
    if (!propertyListData || !outDictionary) {
        return BF_ERR;
    }
    BFPropertyListDictionaryReset(outDictionary);

    BFString xmlString = BFStringCreateWithData(propertyListData);
    const char *xmlCString = BFStringGetCString(&xmlString);
    if (!xmlCString) {
        BFStringReset(&xmlString);
        return BF_ERR;
    }
    const char *dictStart = strstr(xmlCString, "<dict>");
    const char *dictEnd   = strstr(xmlCString, "</dict>");
    if (!dictStart || !dictEnd || dictEnd < dictStart) {
        BFStringReset(&xmlString);
        return BF_ERR;
    }
    dictStart += strlen("<dict>");

    const char *cursor = dictStart;
    while (cursor < dictEnd) {
        const char *keyOpen = strstr(cursor, "<key>");
        if (!keyOpen || keyOpen >= dictEnd) {
            break;
        }
        keyOpen += strlen("<key>");
        const char *keyClose = strstr(keyOpen, "</key>");
        if (!keyClose || keyClose > dictEnd) {
            BFPropertyListDictionaryReset(outDictionary);
            BFStringReset(&xmlString);
            return BF_ERR;
        }

        BFString keyString = BFStringCreate();
        if (BFPropertyListDecodeEscaped(keyOpen, (size_t)(keyClose - keyOpen), &keyString) != BF_OK) {
            BFStringReset(&keyString);
            BFPropertyListDictionaryReset(outDictionary);
            BFStringReset(&xmlString);
            return BF_ERR;
        }

        cursor = keyClose + strlen("</key>");
        BFPropertyListSkipWhitespace(&cursor);

        if (cursor >= dictEnd) {
            BFStringReset(&keyString);
            BFPropertyListDictionaryReset(outDictionary);
            BFStringReset(&xmlString);
            return BF_ERR;
        }

        if (strncmp(cursor, "<string>", 8U) == 0) {
            const char *valueOpen  = cursor + 8U;
            const char *valueClose = strstr(valueOpen, "</string>");
            if (!valueClose || valueClose > dictEnd) {
                BFStringReset(&keyString);
                BFPropertyListDictionaryReset(outDictionary);
                BFStringReset(&xmlString);
                return BF_ERR;
            }
            BFString valueString = BFStringCreate();
            if (BFPropertyListDecodeEscaped(valueOpen, (size_t)(valueClose - valueOpen), &valueString) != BF_OK) {
                BFStringReset(&valueString);
                BFStringReset(&keyString);
                BFPropertyListDictionaryReset(outDictionary);
                BFStringReset(&xmlString);
                return BF_ERR;
            }
            if (BFPropertyListDictionarySetString(outDictionary, &keyString, &valueString) != BF_OK) {
                BFStringReset(&valueString);
                BFStringReset(&keyString);
                BFPropertyListDictionaryReset(outDictionary);
                BFStringReset(&xmlString);
                return BF_ERR;
            }
            BFStringReset(&valueString);
            cursor = valueClose + strlen("</string>");
        } else if (strncmp(cursor, "<integer>", 9U) == 0) {
            const char *valueOpen  = cursor + 9U;
            const char *valueClose = strstr(valueOpen, "</integer>");
            if (!valueClose || valueClose > dictEnd) {
                BFStringReset(&keyString);
                BFPropertyListDictionaryReset(outDictionary);
                BFStringReset(&xmlString);
                return BF_ERR;
            }
            const char *trimStart = valueOpen;
            const char *trimEnd   = valueClose;
            BFPropertyListTrimWhitespace(&trimStart, &trimEnd);
            BFString numberString = BFStringCreateWithUTF8Bytes(trimStart, (size_t)(trimEnd - trimStart));
            BFNumber numberValue;
            if (BFNumberParseDecimalCString(&numberValue, BFStringGetCString(&numberString)) != BF_OK) {
                BFStringReset(&numberString);
                BFStringReset(&keyString);
                BFPropertyListDictionaryReset(outDictionary);
                BFStringReset(&xmlString);
                return BF_ERR;
            }
            if (BFPropertyListDictionarySetNumber(outDictionary, &keyString, &numberValue) != BF_OK) {
                BFStringReset(&numberString);
                BFStringReset(&keyString);
                BFPropertyListDictionaryReset(outDictionary);
                BFStringReset(&xmlString);
                return BF_ERR;
            }
            BFStringReset(&numberString);
            cursor = valueClose + strlen("</integer>");
        } else if (strncmp(cursor, "<real>", 6U) == 0) {
            const char *valueOpen  = cursor + 6U;
            const char *valueClose = strstr(valueOpen, "</real>");
            if (!valueClose || valueClose > dictEnd) {
                BFStringReset(&keyString);
                BFPropertyListDictionaryReset(outDictionary);
                BFStringReset(&xmlString);
                return BF_ERR;
            }
            const char *trimStart = valueOpen;
            const char *trimEnd   = valueClose;
            BFPropertyListTrimWhitespace(&trimStart, &trimEnd);
            BFString numberString = BFStringCreateWithUTF8Bytes(trimStart, (size_t)(trimEnd - trimStart));
            BFNumber numberValue;
            if (BFNumberParseDecimalCString(&numberValue, BFStringGetCString(&numberString)) != BF_OK) {
                BFStringReset(&numberString);
                BFStringReset(&keyString);
                BFPropertyListDictionaryReset(outDictionary);
                BFStringReset(&xmlString);
                return BF_ERR;
            }
            if (BFPropertyListDictionarySetNumber(outDictionary, &keyString, &numberValue) != BF_OK) {
                BFStringReset(&numberString);
                BFStringReset(&keyString);
                BFPropertyListDictionaryReset(outDictionary);
                BFStringReset(&xmlString);
                return BF_ERR;
            }
            BFStringReset(&numberString);
            cursor = valueClose + strlen("</real>");
        } else if (strncmp(cursor, "<data>", 6U) == 0) {
            const char *valueOpen  = cursor + 6U;
            const char *valueClose = strstr(valueOpen, "</data>");
            if (!valueClose || valueClose > dictEnd) {
                BFStringReset(&keyString);
                BFPropertyListDictionaryReset(outDictionary);
                BFStringReset(&xmlString);
                return BF_ERR;
            }
            BFData dataValue = BFDataCreate(0U);
            if (BFPropertyListDecodeBase64Segment(valueOpen, (size_t)(valueClose - valueOpen), &dataValue) != BF_OK) {
                BFDataReset(&dataValue);
                BFStringReset(&keyString);
                BFPropertyListDictionaryReset(outDictionary);
                BFStringReset(&xmlString);
                return BF_ERR;
            }
            if (BFPropertyListDictionarySetData(outDictionary, &keyString, &dataValue) != BF_OK) {
                BFDataReset(&dataValue);
                BFStringReset(&keyString);
                BFPropertyListDictionaryReset(outDictionary);
                BFStringReset(&xmlString);
                return BF_ERR;
            }
            BFDataReset(&dataValue);
            cursor = valueClose + strlen("</data>");
        } else if (strncmp(cursor, "<true/>", 7U) == 0) {
            if (BFPropertyListDictionarySetBoolean(outDictionary, &keyString, 1) != BF_OK) {
                BFStringReset(&keyString);
                BFPropertyListDictionaryReset(outDictionary);
                BFStringReset(&xmlString);
                return BF_ERR;
            }
            cursor = cursor + 7U;
        } else if (strncmp(cursor, "<false/>", 8U) == 0) {
            if (BFPropertyListDictionarySetBoolean(outDictionary, &keyString, 0) != BF_OK) {
                BFStringReset(&keyString);
                BFPropertyListDictionaryReset(outDictionary);
                BFStringReset(&xmlString);
                return BF_ERR;
            }
            cursor = cursor + 8U;
        } else {
            BFStringReset(&keyString);
            BFPropertyListDictionaryReset(outDictionary);
            BFStringReset(&xmlString);
            return BF_ERR;
        }

        BFStringReset(&keyString);
        BFPropertyListSkipWhitespace(&cursor);
    }

    BFStringReset(&xmlString);
    return BF_OK;
}

static void BFPropertyListValueReset(BFPropertyListValue *value) {
    if (!value) {
        return;
    }
    switch (value->type) {
        case BFPropertyListValueTypeString:
            BFStringReset(&value->value.stringValue);
            break;
        case BFPropertyListValueTypeData:
            BFDataReset(&value->value.dataValue);
            break;
        default:
            break;
    }
    memset(&value->value, 0, sizeof(value->value));
    value->type = BFPropertyListValueTypeString;
}

static int BFPropertyListValueSetString(BFPropertyListValue *value, const BFString *stringValue) {
    if (!value || !stringValue) {
        return BF_ERR;
    }
    BFPropertyListValueReset(value);
    value->type = BFPropertyListValueTypeString;
    value->value.stringValue = BFStringCreate();
    if (BFStringCopy(&value->value.stringValue, stringValue) != BF_OK) {
        BFStringReset(&value->value.stringValue);
        return BF_ERR;
    }
    return BF_OK;
}

static int BFPropertyListValueSetNumber(BFPropertyListValue *value, const BFNumber *numberValue) {
    if (!value || !numberValue) {
        return BF_ERR;
    }
    BFPropertyListValueReset(value);
    value->type                 = BFPropertyListValueTypeNumber;
    value->value.numberValue    = *numberValue;
    return BF_OK;
}

static int BFPropertyListValueSetData(BFPropertyListValue *value, const BFData *dataValue) {
    if (!value || !dataValue) {
        return BF_ERR;
    }
    BFPropertyListValueReset(value);
    value->type              = BFPropertyListValueTypeData;
    value->value.dataValue   = BFDataCreateWithBytes(BFDataGetBytes(dataValue), BFDataGetLength(dataValue));
    if (BFDataGetLength(dataValue) > 0U && BFDataGetBytes(&value->value.dataValue) == NULL) {
        BFDataReset(&value->value.dataValue);
        return BF_ERR;
    }
    return BF_OK;
}

static int BFPropertyListValueSetBoolean(BFPropertyListValue *value, int booleanValue) {
    if (!value) {
        return BF_ERR;
    }
    BFPropertyListValueReset(value);
    value->type                    = BFPropertyListValueTypeBoolean;
    value->value.booleanValue      = booleanValue ? 1 : 0;
    return BF_OK;
}

static int BFPropertyListEnsureCapacity(BFPropertyListDictionary *dictionary, size_t requiredCount) {
    if (!dictionary) {
        return BF_ERR;
    }
    if (requiredCount <= dictionary->capacity) {
        return BF_OK;
    }
    size_t newCapacity = dictionary->capacity == 0U ? 4U : dictionary->capacity;
    while (newCapacity < requiredCount) {
        if (newCapacity > (SIZE_MAX / 2U)) {
            newCapacity = requiredCount;
            break;
        }
        newCapacity *= 2U;
    }
    size_t allocationSize = newCapacity * sizeof(BFPropertyListDictionaryEntry);
    BFPropertyListDictionaryEntry *newEntries = (BFPropertyListDictionaryEntry *)BFMemoryAllocate(allocationSize);
    if (!newEntries) {
        return BF_ERR;
    }
    if (dictionary->entries && dictionary->count > 0U) {
        memcpy(newEntries, dictionary->entries, dictionary->count * sizeof(BFPropertyListDictionaryEntry));
    }
    if (dictionary->entries) {
        BFMemoryRelease(dictionary->entries);
    }
    dictionary->entries  = newEntries;
    dictionary->capacity = newCapacity;
    return BF_OK;
}

static BFPropertyListDictionaryEntry *BFPropertyListDictionaryFindEntry(BFPropertyListDictionary *dictionary, const BFString *key) {
    if (!dictionary || !key) {
        return NULL;
    }
    for (size_t index = 0U; index < dictionary->count; ++index) {
        if (BFStringIsEqual(&dictionary->entries[index].key, key)) {
            return &dictionary->entries[index];
        }
    }
    return NULL;
}

static const BFPropertyListDictionaryEntry *BFPropertyListDictionaryFindEntryConst(const BFPropertyListDictionary *dictionary, const BFString *key) {
    if (!dictionary || !key) {
        return NULL;
    }
    for (size_t index = 0U; index < dictionary->count; ++index) {
        if (BFStringIsEqual(&dictionary->entries[index].key, key)) {
            return &dictionary->entries[index];
        }
    }
    return NULL;
}

static BFPropertyListDictionaryEntry *BFPropertyListDictionaryEnsureEntry(BFPropertyListDictionary *dictionary, const BFString *key) {
    BFPropertyListDictionaryEntry *existing = BFPropertyListDictionaryFindEntry(dictionary, key);
    if (existing) {
        return existing;
    }
    if (BFPropertyListEnsureCapacity(dictionary, dictionary->count + 1U) != BF_OK) {
        return NULL;
    }
    BFPropertyListDictionaryEntry *entry = &dictionary->entries[dictionary->count];
    entry->key   = BFStringCreate();
    entry->value = (BFPropertyListValue){0};
    if (BFStringCopy(&entry->key, key) != BF_OK) {
        BFStringReset(&entry->key);
        return NULL;
    }
    entry->value.type = BFPropertyListValueTypeString;
    dictionary->count += 1U;
    return entry;
}

static int BFPropertyListAppendEscaped(const BFString *source, BFString *destination) {
    if (!source || !destination) {
        return BF_ERR;
    }
    const char *charactersPointer = BFStringGetCString(source);
    size_t      charactersLength  = BFStringGetLength(source);
    size_t      chunkStart        = 0U;
    for (size_t index = 0U; index < charactersLength; ++index) {
        char current = charactersPointer[index];
        const char *replacement = NULL;
        switch (current) {
            case '&':
                replacement = "&amp;";
                break;
            case '<':
                replacement = "&lt;";
                break;
            case '>':
                replacement = "&gt;";
                break;
            case '\"':
                replacement = "&quot;";
                break;
            case '\'':
                replacement = "&apos;";
                break;
            default:
                break;
        }
        if (replacement) {
            if (index > chunkStart) {
                if (BFStringAppendUTF8Bytes(destination, charactersPointer + chunkStart, index - chunkStart) != BF_OK) {
                    return BF_ERR;
                }
            }
            if (BFStringAppendCString(destination, replacement) != BF_OK) {
                return BF_ERR;
            }
            chunkStart = index + 1U;
        }
    }
    if (chunkStart < charactersLength) {
        if (BFStringAppendUTF8Bytes(destination, charactersPointer + chunkStart, charactersLength - chunkStart) != BF_OK) {
            return BF_ERR;
        }
    }
    return BF_OK;
}

static int BFPropertyListDecodeEscaped(const char *charactersPointer, size_t charactersLength, BFString *destination) {
    if (!destination) {
        return BF_ERR;
    }
    BFStringReset(destination);
    size_t index = 0U;
    while (index < charactersLength) {
        char current = charactersPointer[index];
        if (current != '&') {
            if (BFStringAppendUTF8Bytes(destination, &charactersPointer[index], 1U) != BF_OK) {
                return BF_ERR;
            }
            index += 1U;
            continue;
        }
        size_t entityEnd = index;
        while (entityEnd < charactersLength && charactersPointer[entityEnd] != ';') {
            entityEnd += 1U;
        }
        if (entityEnd >= charactersLength) {
            return BF_ERR;
        }
        size_t entityLength = entityEnd - index + 1U;
        if (entityLength == 5U && strncmp(&charactersPointer[index], "&amp;", 5U) == 0) {
            if (BFStringAppendCString(destination, "&") != BF_OK) {
                return BF_ERR;
            }
        } else if (entityLength == 4U && strncmp(&charactersPointer[index], "&lt;", 4U) == 0) {
            if (BFStringAppendCString(destination, "<") != BF_OK) {
                return BF_ERR;
            }
        } else if (entityLength == 4U && strncmp(&charactersPointer[index], "&gt;", 4U) == 0) {
            if (BFStringAppendCString(destination, ">") != BF_OK) {
                return BF_ERR;
            }
        } else if (entityLength == 6U && strncmp(&charactersPointer[index], "&quot;", 6U) == 0) {
            if (BFStringAppendCString(destination, "\"") != BF_OK) {
                return BF_ERR;
            }
        } else if (entityLength == 6U && strncmp(&charactersPointer[index], "&apos;", 6U) == 0) {
            if (BFStringAppendCString(destination, "'") != BF_OK) {
                return BF_ERR;
            }
        } else {
            return BF_ERR;
        }
        index = entityEnd + 1U;
    }
    return BF_OK;
}

static void BFPropertyListSkipWhitespace(const char **cursorPointer) {
    if (!cursorPointer || !*cursorPointer) {
        return;
    }
    while (**cursorPointer != '\0' && isspace((unsigned char)**cursorPointer)) {
        *cursorPointer += 1;
    }
}

static void BFPropertyListTrimWhitespace(const char **startPointer, const char **endPointer) {
    if (!startPointer || !endPointer || !*startPointer || !*endPointer) {
        return;
    }
    const char *start = *startPointer;
    const char *end   = *endPointer;
    while (start < end && isspace((unsigned char)*start)) {
        start += 1;
    }
    while (end > start && isspace((unsigned char)*(end - 1))) {
        end -= 1;
    }
    *startPointer = start;
    *endPointer   = end;
}

static int BFPropertyListDecodeBase64Segment(const char *charactersPointer, size_t charactersLength, BFData *outData) {
    if (!charactersPointer || !outData) {
        return BF_ERR;
    }
    BFString compacted = BFStringCreate();
    for (size_t index = 0U; index < charactersLength; ++index) {
        char current = charactersPointer[index];
        if (isspace((unsigned char)current)) {
            continue;
        }
        if (BFStringAppendUTF8Bytes(&compacted, &charactersPointer[index], 1U) != BF_OK) {
            BFStringReset(&compacted);
            return BF_ERR;
        }
    }
    int status = BFBase64CodecDecodeStringToData(&compacted, outData);
    BFStringReset(&compacted);
    return status;
}
