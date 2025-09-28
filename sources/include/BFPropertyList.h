// BFPropertyList — minimal XML plist reader/writer focused on dictionary payloads.

#ifndef BF_PROPERTY_LIST_H
#define BF_PROPERTY_LIST_H

#include "BFBase64Codec.h"
#include "BFNumber.h"
#include "BFString.h"
#include "BFData.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum BFPropertyListValueType {
    BFPropertyListValueTypeString = 0,
    BFPropertyListValueTypeNumber,
    BFPropertyListValueTypeData,
    BFPropertyListValueTypeBoolean
} BFPropertyListValueType;

typedef struct BFPropertyListValue {
    BFPropertyListValueType type;
    union {
        BFString stringValue;
        BFNumber numberValue;
        BFData   dataValue;
        int      booleanValue;
    } value;
} BFPropertyListValue;

typedef struct BFPropertyListDictionaryEntry {
    BFString             key;
    BFPropertyListValue  value;
} BFPropertyListDictionaryEntry;

typedef struct BFPropertyListDictionary {
    BFPropertyListDictionaryEntry *entries;
    size_t                         count;
    size_t                         capacity;
} BFPropertyListDictionary;

BFPropertyListDictionary BFPropertyListDictionaryCreate(void);
void                     BFPropertyListDictionaryReset(BFPropertyListDictionary *dictionary);
size_t                   BFPropertyListDictionaryGetCount(const BFPropertyListDictionary *dictionary);
const BFPropertyListDictionaryEntry *BFPropertyListDictionaryGetEntryAtIndex(const BFPropertyListDictionary *dictionary, size_t index);

int BFPropertyListDictionarySetString(BFPropertyListDictionary *dictionary, const BFString *key, const BFString *value);
int BFPropertyListDictionarySetNumber(BFPropertyListDictionary *dictionary, const BFString *key, const BFNumber *value);
int BFPropertyListDictionarySetData(BFPropertyListDictionary *dictionary, const BFString *key, const BFData *value);
int BFPropertyListDictionarySetBoolean(BFPropertyListDictionary *dictionary, const BFString *key, int booleanValue);

int BFPropertyListDictionaryGetString(const BFPropertyListDictionary *dictionary, const BFString *key, BFString *outString);
int BFPropertyListDictionaryGetNumber(const BFPropertyListDictionary *dictionary, const BFString *key, BFNumber *outNumber);
int BFPropertyListDictionaryGetData(const BFPropertyListDictionary *dictionary, const BFString *key, BFData *outData);
int BFPropertyListDictionaryGetBoolean(const BFPropertyListDictionary *dictionary, const BFString *key, int *outBoolean);

int BFPropertyListDictionaryWriteXML(const BFPropertyListDictionary *dictionary, BFString *outString);
int BFPropertyListDictionaryWriteToData(const BFPropertyListDictionary *dictionary, BFData *outData);
int BFPropertyListDictionaryReadXML(const BFData *propertyListData, BFPropertyListDictionary *outDictionary);

#ifdef __cplusplus
}
#endif

#endif // BF_PROPERTY_LIST_H
