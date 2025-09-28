// BFNumber — numeric value helper similar to CoreFoundation CFNumber.

#ifndef BF_NUMBER_H
#define BF_NUMBER_H

#include <stdint.h>

#include "BFString.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum BFNumberType {
    BFNumberTypeSigned = 0,
    BFNumberTypeUnsigned,
    BFNumberTypeFloating
} BFNumberType;

typedef struct BFNumber {
    BFNumberType type;
    union {
        int64_t  signedValue;
        uint64_t unsignedValue;
        double   floatingValue;
    } value;
} BFNumber;

BFNumber     BFNumberCreateWithInt64(int64_t signedValue);
BFNumber     BFNumberCreateWithUInt64(uint64_t unsignedValue);
BFNumber     BFNumberCreateWithDouble(double floatingValue);
BFNumberType BFNumberGetType(const BFNumber *number);
int          BFNumberGetInt64(const BFNumber *number, int64_t *outValue);
int          BFNumberGetUInt64(const BFNumber *number, uint64_t *outValue);
int          BFNumberGetDouble(const BFNumber *number, double *outValue);
int          BFNumberCompare(const BFNumber *leftNumber, const BFNumber *rightNumber, int *comparisonResult);
int          BFNumberFormatDecimal(const BFNumber *number, BFString *outString);
int          BFNumberParseDecimalCString(BFNumber *number, const char *decimalCString);

#ifdef __cplusplus
}
#endif

#endif // BF_NUMBER_H
