#include "BFNumber.h"

#include "BFCommon.h"

#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

BFNumber BFNumberCreateWithInt64(int64_t signedValue) {
    BFNumber number;
    number.type              = BFNumberTypeSigned;
    number.value.signedValue = signedValue;
    return number;
}

BFNumber BFNumberCreateWithUInt64(uint64_t unsignedValue) {
    BFNumber number;
    number.type                = BFNumberTypeUnsigned;
    number.value.unsignedValue = unsignedValue;
    return number;
}

BFNumber BFNumberCreateWithDouble(double floatingValue) {
    BFNumber number;
    number.type               = BFNumberTypeFloating;
    number.value.floatingValue = floatingValue;
    return number;
}

BFNumberType BFNumberGetType(const BFNumber *number) {
    if (!number) {
        return BFNumberTypeSigned;
    }
    return number->type;
}

int BFNumberGetInt64(const BFNumber *number, int64_t *outValue) {
    if (!number || !outValue) {
        return BF_ERR;
    }
    switch (number->type) {
        case BFNumberTypeSigned:
            *outValue = number->value.signedValue;
            return BF_OK;
        case BFNumberTypeUnsigned:
            if (number->value.unsignedValue > (uint64_t)INT64_MAX) {
                return BF_ERR;
            }
            *outValue = (int64_t)number->value.unsignedValue;
            return BF_OK;
        case BFNumberTypeFloating:
            if (!isfinite(number->value.floatingValue)) {
                return BF_ERR;
            }
            if (number->value.floatingValue < (double)INT64_MIN || number->value.floatingValue > (double)INT64_MAX) {
                return BF_ERR;
            }
            *outValue = (int64_t)number->value.floatingValue;
            return BF_OK;
        default:
            break;
    }
    return BF_ERR;
}

int BFNumberGetUInt64(const BFNumber *number, uint64_t *outValue) {
    if (!number || !outValue) {
        return BF_ERR;
    }
    switch (number->type) {
        case BFNumberTypeUnsigned:
            *outValue = number->value.unsignedValue;
            return BF_OK;
        case BFNumberTypeSigned:
            if (number->value.signedValue < 0) {
                return BF_ERR;
            }
            *outValue = (uint64_t)number->value.signedValue;
            return BF_OK;
        case BFNumberTypeFloating:
            if (!isfinite(number->value.floatingValue) || number->value.floatingValue < 0.0) {
                return BF_ERR;
            }
            if (number->value.floatingValue > (double)UINT64_MAX) {
                return BF_ERR;
            }
            *outValue = (uint64_t)number->value.floatingValue;
            return BF_OK;
        default:
            break;
    }
    return BF_ERR;
}

int BFNumberGetDouble(const BFNumber *number, double *outValue) {
    if (!number || !outValue) {
        return BF_ERR;
    }
    switch (number->type) {
        case BFNumberTypeSigned:
            *outValue = (double)number->value.signedValue;
            return BF_OK;
        case BFNumberTypeUnsigned:
            *outValue = (double)number->value.unsignedValue;
            return BF_OK;
        case BFNumberTypeFloating:
            *outValue = number->value.floatingValue;
            return BF_OK;
        default:
            break;
    }
    return BF_ERR;
}

int BFNumberCompare(const BFNumber *leftNumber, const BFNumber *rightNumber, int *comparisonResult) {
    if (!leftNumber || !rightNumber || !comparisonResult) {
        return BF_ERR;
    }
    if (leftNumber->type == BFNumberTypeFloating || rightNumber->type == BFNumberTypeFloating) {
        double leftDouble = 0.0;
        double rightDouble = 0.0;
        if (BFNumberGetDouble(leftNumber, &leftDouble) != BF_OK) {
            return BF_ERR;
        }
        if (BFNumberGetDouble(rightNumber, &rightDouble) != BF_OK) {
            return BF_ERR;
        }
        long double leftValue  = (long double)leftDouble;
        long double rightValue = (long double)rightDouble;
        if (leftValue < rightValue) {
            *comparisonResult = -1;
        } else if (leftValue > rightValue) {
            *comparisonResult = 1;
        } else {
            *comparisonResult = 0;
        }
        return BF_OK;
    }
    if (leftNumber->type == BFNumberTypeSigned && rightNumber->type == BFNumberTypeSigned) {
        if (leftNumber->value.signedValue < rightNumber->value.signedValue) {
            *comparisonResult = -1;
        } else if (leftNumber->value.signedValue > rightNumber->value.signedValue) {
            *comparisonResult = 1;
        } else {
            *comparisonResult = 0;
        }
        return BF_OK;
    }
    if (leftNumber->type == BFNumberTypeUnsigned && rightNumber->type == BFNumberTypeUnsigned) {
        if (leftNumber->value.unsignedValue < rightNumber->value.unsignedValue) {
            *comparisonResult = -1;
        } else if (leftNumber->value.unsignedValue > rightNumber->value.unsignedValue) {
            *comparisonResult = 1;
        } else {
            *comparisonResult = 0;
        }
        return BF_OK;
    }
    if (leftNumber->type == BFNumberTypeSigned && rightNumber->type == BFNumberTypeUnsigned) {
        if (leftNumber->value.signedValue < 0) {
            *comparisonResult = -1;
            return BF_OK;
        }
        uint64_t leftUnsigned = (uint64_t)leftNumber->value.signedValue;
        if (leftUnsigned < rightNumber->value.unsignedValue) {
            *comparisonResult = -1;
        } else if (leftUnsigned > rightNumber->value.unsignedValue) {
            *comparisonResult = 1;
        } else {
            *comparisonResult = 0;
        }
        return BF_OK;
    }
    if (leftNumber->type == BFNumberTypeUnsigned && rightNumber->type == BFNumberTypeSigned) {
        if (rightNumber->value.signedValue < 0) {
            *comparisonResult = 1;
            return BF_OK;
        }
        uint64_t rightUnsigned = (uint64_t)rightNumber->value.signedValue;
        if (leftNumber->value.unsignedValue < rightUnsigned) {
            *comparisonResult = -1;
        } else if (leftNumber->value.unsignedValue > rightUnsigned) {
            *comparisonResult = 1;
        } else {
            *comparisonResult = 0;
        }
        return BF_OK;
    }
    return BF_ERR;
}

int BFNumberFormatDecimal(const BFNumber *number, BFString *outString) {
    if (!number || !outString) {
        return BF_ERR;
    }
    char buffer[128];
    int  written = -1;
    switch (number->type) {
        case BFNumberTypeSigned:
            written = snprintf(buffer, sizeof(buffer), "%" PRId64, number->value.signedValue);
            break;
        case BFNumberTypeUnsigned:
            written = snprintf(buffer, sizeof(buffer), "%" PRIu64, number->value.unsignedValue);
            break;
        case BFNumberTypeFloating:
            written = snprintf(buffer, sizeof(buffer), "%.17g", number->value.floatingValue);
            break;
        default:
            return BF_ERR;
    }
    if (written < 0 || (size_t)written >= sizeof(buffer)) {
        return BF_ERR;
    }
    return BFStringSetFromCString(outString, buffer);
}

int BFNumberParseDecimalCString(BFNumber *number, const char *decimalCString) {
    if (!number || !decimalCString) {
        return BF_ERR;
    }
    char *endPointer = NULL;
    errno           = 0;
    long long signedValue = strtoll(decimalCString, &endPointer, 10);
    if (errno == 0 && endPointer && *endPointer == '\0') {
        *number = BFNumberCreateWithInt64((int64_t)signedValue);
        return BF_OK;
    }

    errno = 0;
    unsigned long long unsignedValue = strtoull(decimalCString, &endPointer, 10);
    if (errno == 0 && endPointer && *endPointer == '\0') {
        *number = BFNumberCreateWithUInt64((uint64_t)unsignedValue);
        return BF_OK;
    }

    errno = 0;
    double floatingValue = strtod(decimalCString, &endPointer);
    if (errno == 0 && endPointer && *endPointer == '\0' && isfinite(floatingValue)) {
        *number = BFNumberCreateWithDouble(floatingValue);
        return BF_OK;
    }

    return BF_ERR;
}
