#include "box/BFBoxProtocolV1.h"

#include <arpa/inet.h>
#include <string.h>

static uint64_t bf_htonll(uint64_t value) {
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    uint32_t high = (uint32_t)(value >> 32);
    uint32_t low  = (uint32_t)(value & 0xFFFFFFFFu);
    uint64_t a    = ((uint64_t)htonl(low)) << 32;
    uint64_t b    = ((uint64_t)htonl(high));
    return a | b;
#else
    return value;
#endif
}

static uint64_t bf_ntohll(uint64_t value) {
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    uint32_t high = (uint32_t)(value >> 32);
    uint32_t low  = (uint32_t)(value & 0xFFFFFFFFu);
    uint64_t a    = ((uint64_t)ntohl(low)) << 32;
    uint64_t b    = ((uint64_t)ntohl(high));
    return a | b;
#else
    return value;
#endif
}

int BFV1Pack(uint8_t *buffer, size_t bufferLength, uint32_t command, uint64_t requestId,
             const void *payload, uint32_t payloadLength) {
    // Compute total frame size: header(1+1+4+4+8) + payload
    const size_t headerSize = 1 + 1 + 4 + 4 + 8;
    const size_t totalSize  = headerSize + (size_t)payloadLength;
    if (buffer == NULL) {
        return -1;
    }
    if (bufferLength < totalSize) {
        return -2;
    }

    // Magic + version
    buffer[0] = (uint8_t)BFV1_MAGIC;
    buffer[1] = (uint8_t)BFV1_VERSION;

    // total_length of the remainder (uint32, big-endian)
    uint32_t remainderLength = (uint32_t)(totalSize - 2); // after magic+version
    uint32_t beRemainder     = htonl(remainderLength);
    memcpy(&buffer[2], &beRemainder, sizeof(beRemainder));

    // command (uint32)
    uint32_t beCommand = htonl(command);
    memcpy(&buffer[6], &beCommand, sizeof(beCommand));

    // request_id (uint64)
    uint64_t beRequestId = bf_htonll(requestId);
    memcpy(&buffer[10], &beRequestId, sizeof(beRequestId));

    // payload
    if (payload != NULL && payloadLength > 0) {
        memcpy(&buffer[18], payload, payloadLength);
    }
    return (int)totalSize;
}

int BFV1Unpack(const uint8_t *buffer, size_t bufferLength, uint32_t *outCommand,
               uint64_t *outRequestId, const uint8_t **outPayload, uint32_t *outPayloadLength) {
    if (buffer == NULL) {
        return -1;
    }
    if (bufferLength < 18) {
        return -2; // not enough for header
    }
    if (buffer[0] != (uint8_t)BFV1_MAGIC) {
        return -3; // wrong magic
    }
    if (buffer[1] != (uint8_t)BFV1_VERSION) {
        return -4; // unsupported version
    }

    uint32_t beRemainder = 0;
    memcpy(&beRemainder, &buffer[2], sizeof(beRemainder));
    uint32_t remainderLength = ntohl(beRemainder);

    size_t expectedTotal = (size_t)remainderLength + 2; // add magic+version
    if (bufferLength < expectedTotal) {
        return -5; // truncated
    }

    uint32_t beCommand = 0;
    memcpy(&beCommand, &buffer[6], sizeof(beCommand));
    uint32_t command = ntohl(beCommand);

    uint64_t beRequestId = 0;
    memcpy(&beRequestId, &buffer[10], sizeof(beRequestId));
    uint64_t requestId = bf_ntohll(beRequestId);

    uint32_t payloadLength = (uint32_t)(expectedTotal - 18);

    if (outCommand) {
        *outCommand = command;
    }
    if (outRequestId) {
        *outRequestId = requestId;
    }
    if (outPayload) {
        *outPayload = &buffer[18];
    }
    if (outPayloadLength) {
        *outPayloadLength = payloadLength;
    }

    return (int)expectedTotal;
}

int BFV1PackStatus(uint8_t *buffer, size_t bufferLength, uint32_t command, uint64_t requestId,
                   uint8_t statusCode, const char *message) {
    const uint8_t *msgBytes = (const uint8_t *)message;
    uint32_t       msgLen   = 0;
    if (message != NULL) {
        msgLen = (uint32_t)strlen(message);
    }
    // payload: 1 byte status + msgLen bytes
    uint32_t payloadLength = 1 + msgLen;
    if (bufferLength < (size_t)(18 + payloadLength)) {
        return -1;
    }
    // Build payload in-place
    uint8_t *payload = buffer + 18;
    payload[0]       = statusCode;
    if (msgLen) {
        memcpy(payload + 1, msgBytes, msgLen);
    }
    // Now pack the whole frame using BFV1Pack
    return BFV1Pack(buffer, bufferLength, command, requestId, payload, payloadLength);
}

int BFV1UnpackStatus(const uint8_t *payload, uint32_t payloadLength, uint8_t *outStatusCode,
                     const uint8_t **outMessage, uint32_t *outMessageLength) {
    if (payload == NULL || payloadLength == 0) {
        return -1;
    }
    if (outStatusCode) {
        *outStatusCode = payload[0];
    }
    if (outMessage) {
        *outMessage = payloadLength > 1 ? payload + 1 : NULL;
    }
    if (outMessageLength) {
        *outMessageLength = payloadLength > 1 ? (payloadLength - 1) : 0;
    }
    return 0;
}
