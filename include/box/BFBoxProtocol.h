#ifndef BF_PROTOCOL_H
#define BF_PROTOCOL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum { BFMessageHello = 1, BFMessagePing = 2, BFMessagePong = 3, BFMessageData = 4 } BFMessageType;

typedef struct {
    uint16_t type;
    uint16_t length;
} BFHeader;

int BFProtocolPack(uint8_t *buffet, size_t buffetLength, BFMessageType type, const void *payload, uint16_t length);

int BFProtocolUnpack(const uint8_t *buffet, size_t buffetLength, BFHeader *header, const uint8_t **payload);

#ifdef __cplusplus
}
#endif

#endif // BF_PROTOCOL_H
