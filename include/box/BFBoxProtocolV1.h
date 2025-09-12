#ifndef BF_BOX_PROTOCOL_V1_H
#define BF_BOX_PROTOCOL_V1_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Unencrypted Box Protocol v1 framing (per SPECS.md)
// Frame layout (big-endian):
//  - 1 byte  : magic 'B' (0x42)
//  - 1 byte  : version (1)
//  - 4 bytes : total_length of the remainder (uint32)
//  - 4 bytes : command (uint32)
//  - 8 bytes : request_id (uint64)
//  - N bytes : payload (command-specific, unencrypted in this phase)

#define BFV1_MAGIC 0x42
#define BFV1_VERSION 0x01

typedef enum BFV1Command {
    BFV1_HELLO  = 1,
    BFV1_PUT    = 2,
    BFV1_GET    = 3,
    BFV1_DELETE = 4,
    BFV1_STATUS = 5,
    BFV1_SEARCH = 6,
    BFV1_BYE    = 7,
} BFV1Command;

typedef enum BFV1StatusCode {
    BFV1_STATUS_OK           = 0,
    BFV1_STATUS_UNAUTHORIZED = 1,
    BFV1_STATUS_FORBIDDEN    = 2,
    BFV1_STATUS_NOT_FOUND    = 3,
    BFV1_STATUS_CONFLICT     = 4,
    BFV1_STATUS_BAD_REQUEST  = 5,
    BFV1_STATUS_TOO_LARGE    = 6,
    BFV1_STATUS_RATE_LIMITED = 7,
    BFV1_STATUS_INTERNAL     = 8,
} BFV1StatusCode;

// Packs a v1 frame into the provided buffer.
// Returns the number of bytes written, or a negative value on error.
int BFV1Pack(uint8_t *buffer, size_t bufferLength, uint32_t command, uint64_t requestId,
             const void *payload, uint32_t payloadLength);

// Unpacks a v1 frame. On success, returns the number of bytes consumed from the buffer
// and fills output parameters when non-NULL. Payload pointer points into the input buffer.
// Returns a negative value on error.
int BFV1Unpack(const uint8_t *buffer, size_t bufferLength, uint32_t *outCommand,
               uint64_t *outRequestId, const uint8_t **outPayload, uint32_t *outPayloadLength);

// Convenience: pack a status payload (first byte is statusCode, remaining is optional text
// message).
int BFV1PackStatus(uint8_t *buffer, size_t bufferLength, uint32_t command, uint64_t requestId,
                   uint8_t statusCode, const char *message);

// Convenience: unpack a status payload. Returns 0 on success, negative on error.
int BFV1UnpackStatus(const uint8_t *payload, uint32_t payloadLength, uint8_t *outStatusCode,
                     const uint8_t **outMessage, uint32_t *outMessageLength);

#ifdef __cplusplus
}
#endif

#endif // BF_BOX_PROTOCOL_V1_H
