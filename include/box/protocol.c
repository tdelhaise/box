#include "box/protocol.h"
#include <string.h>
#include <arpa/inet.h>

int BFProtocolPack(uint8_t *buffet, size_t buffetLength, BFMessageType type, const void *payload, uint16_t length) {
        if (buffetLength < sizeof(BFHeader) + length)
                return -1;

        BFHeader *header = (BFHeader*)buffet;
        header->type = htons((uint16_t)type);
        header->length = htons(length);

        if (length && payload)
                memcpy(buffet + sizeof(BFHeader), payload, length);

        return sizeof(BFHeader) + length;
}

int BFProtocolUnpack(const uint8_t *buffet, size_t buffetLength, BFHeader *header, const uint8_t **payload) {
        if (buffetLength < sizeof(BFHeader))
                return -1;

        const BFHeader *h = (const BFHeader*)buffet;
        uint16_t length = ntohs(h->length);

        if (buffetLength < sizeof(BFHeader) + length)
                return -1;

        if (header) {
                header->type = ntohs(h->type);
                header->length = length;
        }
        if (payload) *payload = buffet + sizeof(BFHeader);

        return sizeof(BFHeader) + length;
}
