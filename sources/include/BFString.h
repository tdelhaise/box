// BFString — UTF-8 owned string helper mirroring CoreFoundation-style utilities.

#ifndef BF_STRING_H
#define BF_STRING_H

#include <stddef.h>

#include "BFData.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BFString {
    char  *characters;
    size_t length;
    size_t capacity;
} BFString;

// Constructors ----------------------------------------------------------------

// Creates an empty BFString.
BFString BFStringCreate(void);

// Creates a BFString by copying a null-terminated C string.
BFString BFStringCreateWithCString(const char *cString);

// Creates a BFString by copying an explicit UTF-8 byte sequence.
BFString BFStringCreateWithUTF8Bytes(const char *charactersPointer, size_t charactersLength);

// Creates a BFString from a BFData buffer (validated as UTF-8, no embedded nulls).
BFString BFStringCreateWithData(const BFData *data);

// Memory management -----------------------------------------------------------

// Releases owned memory and resets the string to empty.
void BFStringReset(BFString *string);

// Assignment ------------------------------------------------------------------

int BFStringSetFromCString(BFString *string, const char *cString);
int BFStringSetFromUTF8Bytes(BFString *string, const char *charactersPointer, size_t charactersLength);
int BFStringSetFromData(BFString *string, const BFData *data);
int BFStringCopy(BFString *destination, const BFString *source);

// Query -----------------------------------------------------------------------

const char *BFStringGetCString(const BFString *string);
size_t      BFStringGetLength(const BFString *string);

// Comparison ------------------------------------------------------------------

int BFStringCompare(const BFString *leftString, const BFString *rightString, int *comparisonResult);
int BFStringIsEqual(const BFString *leftString, const BFString *rightString);

// Mutation --------------------------------------------------------------------

int BFStringAppendCString(BFString *string, const char *cString);
int BFStringAppendString(BFString *string, const BFString *otherString);
int BFStringAppendUTF8Bytes(BFString *string, const char *charactersPointer, size_t charactersLength);
int BFStringAppendData(BFString *string, const BFData *data);

// Conversion ------------------------------------------------------------------

int BFStringCopyToData(const BFString *string, BFData *outData);

#ifdef __cplusplus
}
#endif

#endif // BF_STRING_H
