#include "BFBoxProtocol.h"
#include "BFBoxProtocolV1.h"
#include "BFCommon.h"
#include <arpa/inet.h>
#include <stdint.h>
#include <string.h>

// -----------------------------------------------------------------------------
// Sérialisation
// -----------------------------------------------------------------------------
static int      gBFProtocolUseV1         = 0;
static uint64_t gBFProtocolNextRequestId = 1U;

static int BFProtocolCommandFromType(BFMessageType type, uint32_t *outCommand) {
    if (!outCommand) {
        return BF_ERR;
    }
    switch (type) {
    case BFMessageHello:
        *outCommand = BFV1_HELLO;
        return BF_OK;
    case BFMessagePing:
    case BFMessagePong:
        *outCommand = BFV1_STATUS;
        return BF_OK;
    case BFMessageData:
        *outCommand = BFV1_PUT;
        return BF_OK;
    default:
        return BF_ERR;
    }
}

static BFMessageType BFProtocolTypeFromCommand(uint32_t command) {
    switch (command) {
    case BFV1_HELLO:
        return BFMessageHello;
    case BFV1_STATUS:
        return BFMessagePing;
    case BFV1_PUT:
        return BFMessageData;
    default:
        return BFMessageData;
    }
}

void BFProtocolSetV1Enabled(int enabled) {
    gBFProtocolUseV1 = (enabled != 0);
}

int BFProtocolIsV1Enabled(void) {
    return gBFProtocolUseV1;
}

int BFProtocolPack(uint8_t *buffet, size_t buffetLength, BFMessageType type, const void *payload, uint16_t length) {
    if (!gBFProtocolUseV1) {
        if (buffetLength < sizeof(BFHeader) + length) {
            return BF_ERR;
        }
        BFHeader *header = (BFHeader *)buffet;
        header->type     = htons((uint16_t)type);
        header->length   = htons(length);
        if (length && payload) {
            memcpy(buffet + sizeof(BFHeader), payload, length);
        }
        return (int)(sizeof(BFHeader) + length);
    }

    uint32_t command = 0U;
    if (BFProtocolCommandFromType(type, &command) != BF_OK) {
        return BF_ERR;
    }
    uint64_t requestId = gBFProtocolNextRequestId++;
    int      packed    = BFV1Pack(buffet, buffetLength, command, requestId, payload, (uint32_t)length);
    if (packed < 0) {
        return packed;
    }
    return packed;
}

// -----------------------------------------------------------------------------
// Désérialisation
// -----------------------------------------------------------------------------
int BFProtocolUnpack(const uint8_t *buffet, size_t buffetLength, BFHeader *header, const uint8_t **payload) {
    if (!gBFProtocolUseV1) {
        if (buffetLength < sizeof(BFHeader)) {
            return BF_ERR;
        }
        const BFHeader *h      = (const BFHeader *)buffet;
        uint16_t        length = ntohs(h->length);
        if (buffetLength < sizeof(BFHeader) + length) {
            return BF_ERR;
        }
        if (header) {
            header->type   = ntohs(h->type);
            header->length = length;
        }
        if (payload) {
            *payload = buffet + sizeof(BFHeader);
        }
        return (int)(sizeof(BFHeader) + length);
    }

    uint32_t       command       = 0U;
    uint64_t       requestId     = 0U;
    const uint8_t *payloadStart  = NULL;
    uint32_t       payloadLength = 0U;
    int            unpacked      = BFV1Unpack(buffet, buffetLength, &command, &requestId, &payloadStart, &payloadLength);
    if (unpacked < 0) {
        return unpacked;
    }
    if (header) {
        BFMessageType type = BFProtocolTypeFromCommand(command);
        header->type       = (uint16_t)type;
        header->length     = (payloadLength > UINT16_MAX) ? UINT16_MAX : (uint16_t)payloadLength;
    }
    if (payload) {
        *payload = payloadStart;
    }
    return unpacked;
}
