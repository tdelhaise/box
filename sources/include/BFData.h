// BFData — resizable byte buffer helper with convenience accessors.

#ifndef BF_DATA_H
#define BF_DATA_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BFData {
    uint8_t *bytes;
    size_t   length;
    size_t   capacity;
    int      ownsMemory;
} BFData;

// Creates a BFData wrapper around an existing memory region without copying.
// The data is not owned; caller must ensure the lifetime of bufferPointer.
BFData BFDataCreateWithBytesNoCopy(uint8_t *bufferPointer, size_t bufferLength);

// Creates an owning BFData with the specified capacity. Length starts at zero.
BFData BFDataCreate(size_t initialCapacity);

// Creates an owning BFData initialized with the provided bytes.
BFData BFDataCreateWithBytes(const uint8_t *bufferPointer, size_t bufferLength);

// Releases owned memory and resets the BFData to an empty state.
void BFDataReset(BFData *data);

// Ensures the buffer has capacity for at least requiredCapacity bytes.
int BFDataEnsureCapacity(BFData *data, size_t requiredCapacity);

// Appends raw bytes to the buffer (resizes as needed).
int BFDataAppendBytes(BFData *data, const uint8_t *bytesPointer, size_t bytesLength);

// Appends a single byte to the buffer.
int BFDataAppendByte(BFData *data, uint8_t byteValue);

// Retrieves a pointer to the underlying bytes (read-only).
const uint8_t *BFDataGetBytes(const BFData *data);

// Retrieves a pointer to the underlying bytes (mutable).
uint8_t *BFDataGetMutableBytes(BFData *data);

// Returns the number of bytes currently stored.
size_t BFDataGetLength(const BFData *data);

// Returns a pointer and length to a range inside the buffer. Returns BF_ERR on invalid range.
int BFDataGetBytesInRange(const BFData *data, size_t offset, size_t length, const uint8_t **outPointer);

// Copies data from a range into destination buffer. Returns BF_ERR if range invalid.
int BFDataCopyBytesInRange(const BFData *data, size_t offset, size_t length, uint8_t *destination);

// Sets the logical length (must be <= capacity). Useful after direct writes.
int BFDataSetLength(BFData *data, size_t newLength);

// Converts buffer contents to a null-terminated string (copy). Returns newly allocated string or NULL.
char *BFDataCopyBytesAsCString(const BFData *data);

// Encodes buffer contents into Base64 string (allocates via BFMemory). Returns NULL on failure.
char *BFDataCopyBase64EncodedString(const BFData *data);

// Decodes a Base64 string into an owning BFData. Returns zero on success.
int BFDataSetFromBase64CString(BFData *data, const char *base64CString);

#ifdef __cplusplus
}
#endif

#endif // BF_DATA_H
