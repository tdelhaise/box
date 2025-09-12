#include "box/BFBoxProtocolV1.h"

#include <arpa/inet.h>
#include <string.h>

static uint64_t bf_htonll(uint64_t value) {
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    uint32_t highPart       = (uint32_t)(value >> 32);
    uint32_t lowPart        = (uint32_t)(value & 0xFFFFFFFFu);
    uint64_t swappedLowHigh = ((uint64_t)htonl(lowPart)) << 32;
    uint64_t swappedHighLow = ((uint64_t)htonl(highPart));
    return swappedLowHigh | swappedHighLow;
#else
    return value;
#endif
}

static uint64_t bf_ntohll(uint64_t value) {
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    uint32_t highPart        = (uint32_t)(value >> 32);
    uint32_t lowPart         = (uint32_t)(value & 0xFFFFFFFFu);
    uint64_t combinedLowHigh = ((uint64_t)ntohl(lowPart)) << 32;
    uint64_t combinedHighLow = ((uint64_t)ntohl(highPart));
    return combinedLowHigh | combinedHighLow;
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

int BFV1PackHello(uint8_t *buffer, size_t bufferLength, uint64_t requestId, uint8_t statusCode,
                  const uint16_t *versions, uint8_t versionCount) {
    if (buffer == NULL) {
        return -1;
    }
    // payload size: 1 (status) + 1 (count) + 2*count (versions)
    uint32_t payloadLength = (uint32_t)(2U * versionCount + 2U);
    if (bufferLength < 18 + payloadLength) {
        return -2;
    }
    uint8_t *payload = buffer + 18;
    payload[0]       = statusCode;
    payload[1]       = versionCount;
    for (uint8_t index = 0; index < versionCount; ++index) {
        uint16_t beVersion = htons(versions[index]);
        memcpy(&payload[2 + index * 2U], &beVersion, sizeof(beVersion));
    }
    return BFV1Pack(buffer, bufferLength, BFV1_HELLO, requestId, payload, payloadLength);
}

int BFV1UnpackHello(const uint8_t *payload, uint32_t payloadLength, uint8_t *outStatusCode,
                    uint16_t *outVersions, uint8_t maxVersions, uint8_t *outVersionCount) {
    if (payload == NULL || payloadLength < 2U) {
        return -1;
    }
    uint8_t status = payload[0];
    uint8_t count  = payload[1];
    if (outStatusCode) {
        *outStatusCode = status;
    }
    if ((uint32_t)(2U + 2U * count) > payloadLength) {
        return -2; // truncated
    }
    if (outVersionCount) {
        *outVersionCount = count;
    }
    if (outVersions && maxVersions > 0 && count > 0) {
        uint8_t copyCount = (count > maxVersions) ? maxVersions : count;
        for (uint8_t index = 0; index < copyCount; ++index) {
            uint16_t beVersion = 0;
            memcpy(&beVersion, &payload[2 + index * 2U], sizeof(beVersion));
            outVersions[index] = ntohs(beVersion);
        }
    }
    return 0;
}

int BFV1PackPut(uint8_t *buffer, size_t bufferLength, uint64_t requestId, const char *queuePath,
                const char *contentType, const uint8_t *data, uint32_t dataLength) {
    if (buffer == NULL || queuePath == NULL || contentType == NULL) {
        return -1;
    }
    uint16_t queuePathLength   = (uint16_t)strlen(queuePath);
    uint16_t contentTypeLength = (uint16_t)strlen(contentType);
    uint32_t payloadLength     = 2U + queuePathLength + 2U + contentTypeLength + 4U + dataLength;
    if (bufferLength < 18 + payloadLength) {
        return -2;
    }
    uint8_t *payload = buffer + 18;
    uint16_t beQP    = htons(queuePathLength);
    memcpy(payload, &beQP, sizeof(beQP));
    memcpy(payload + 2, queuePath, queuePathLength);
    uint16_t beCT = htons(contentTypeLength);
    memcpy(payload + 2 + queuePathLength, &beCT, sizeof(beCT));
    memcpy(payload + 4 + queuePathLength, contentType, contentTypeLength);
    uint32_t beDL = htonl(dataLength);
    memcpy(payload + 4 + queuePathLength + contentTypeLength, &beDL, sizeof(beDL));
    if (dataLength && data) {
        memcpy(payload + 8 + queuePathLength + contentTypeLength, data, dataLength);
    }
    return BFV1Pack(buffer, bufferLength, BFV1_PUT, requestId, payload, payloadLength);
}

int BFV1UnpackPut(const uint8_t *payload, uint32_t payloadLength, const uint8_t **outQueuePath,
                  uint16_t *outQueuePathLength, const uint8_t **outContentType,
                  uint16_t *outContentTypeLength, const uint8_t **outData,
                  uint32_t *outDataLength) {
    if (payload == NULL || payloadLength < 2U) {
        return -1;
    }
    uint16_t beQP = 0;
    memcpy(&beQP, payload, sizeof(beQP));
    uint16_t queuePathLength = ntohs(beQP);
    if ((uint32_t)(2U + queuePathLength + 2U) > payloadLength) {
        return -2;
    }
    const uint8_t *queuePathPointer = payload + 2;
    uint16_t       beCT             = 0;
    memcpy(&beCT, payload + 2 + queuePathLength, sizeof(beCT));
    uint16_t contentTypeLength = ntohs(beCT);
    if ((uint32_t)(4U + queuePathLength + contentTypeLength + 4U) > payloadLength) {
        return -3;
    }
    const uint8_t *contentTypePointer = payload + 4 + queuePathLength;
    uint32_t       beDL               = 0;
    memcpy(&beDL, payload + 4 + queuePathLength + contentTypeLength, sizeof(beDL));
    uint32_t dataLength = ntohl(beDL);
    if ((uint32_t)(8U + queuePathLength + contentTypeLength + dataLength) != payloadLength) {
        return -4;
    }
    const uint8_t *dataPointer = payload + 8 + queuePathLength + contentTypeLength;
    if (outQueuePath)
        *outQueuePath = queuePathPointer;
    if (outQueuePathLength)
        *outQueuePathLength = queuePathLength;
    if (outContentType)
        *outContentType = contentTypePointer;
    if (outContentTypeLength)
        *outContentTypeLength = contentTypeLength;
    if (outData)
        *outData = dataPointer;
    if (outDataLength)
        *outDataLength = dataLength;
    return 0;
}

int BFV1PackGet(uint8_t *buffer, size_t bufferLength, uint64_t requestId, const char *queuePath) {
    if (buffer == NULL || queuePath == NULL) {
        return -1;
    }
    uint16_t queuePathLength = (uint16_t)strlen(queuePath);
    uint32_t payloadLength   = 2U + queuePathLength;
    if (bufferLength < 18 + payloadLength) {
        return -2;
    }
    uint8_t *payload = buffer + 18;
    uint16_t beQP    = htons(queuePathLength);
    memcpy(payload, &beQP, sizeof(beQP));
    memcpy(payload + 2, queuePath, queuePathLength);
    return BFV1Pack(buffer, bufferLength, BFV1_GET, requestId, payload, payloadLength);
}

int BFV1UnpackGet(const uint8_t *payload, uint32_t payloadLength, const uint8_t **outQueuePath,
                  uint16_t *outQueuePathLength) {
    if (payload == NULL || payloadLength < 2U) {
        return -1;
    }
    uint16_t beQP = 0;
    memcpy(&beQP, payload, sizeof(beQP));
    uint16_t queuePathLength = ntohs(beQP);
    if ((uint32_t)(2U + queuePathLength) != payloadLength) {
        return -2;
    }
    if (outQueuePath)
        *outQueuePath = payload + 2;
    if (outQueuePathLength)
        *outQueuePathLength = queuePathLength;
    return 0;
}
