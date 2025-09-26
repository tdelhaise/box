#include "BFBoxProtocol.h"
#include "BFBoxProtocolV1.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    uint8_t     buffet[256];
    const char *message = "hello";
    int         packed  = BFProtocolPack(buffet, sizeof(buffet), BFMessageHello, message, (uint16_t)strlen(message));
    assert(packed > 0);

    BFHeader       header;
    const uint8_t *payload  = NULL;
    int            unpacked = BFProtocolUnpack(buffet, (size_t)packed, &header, &payload);
    assert(unpacked == packed);
    assert(header.type == BFMessageHello);
    assert(header.length == strlen(message));
    assert(memcmp(payload, message, header.length) == 0);

    BFProtocolSetV1Enabled(1);
    const char *messageV1 = "bonjour";
    packed                = BFProtocolPack(buffet, sizeof(buffet), BFMessageHello, messageV1, (uint16_t)strlen(messageV1));
    assert(packed > 0);

    BFHeader       headerV1;
    const uint8_t *payloadV1  = NULL;
    int            unpackedV1 = BFProtocolUnpack(buffet, (size_t)packed, &headerV1, &payloadV1);
    assert(unpackedV1 == packed);
    assert(headerV1.type == BFMessageHello);
    assert(headerV1.length == strlen(messageV1));
    assert(memcmp(payloadV1, messageV1, headerV1.length) == 0);

    uint32_t       commandV1       = 0;
    uint64_t       requestIdV1     = 0;
    const uint8_t *payloadRawV1    = NULL;
    uint32_t       payloadRawLenV1 = 0;
    int            v1Unpacked      = BFV1Unpack(buffet, (size_t)packed, &commandV1, &requestIdV1, &payloadRawV1, &payloadRawLenV1);
    assert(v1Unpacked == packed);
    assert(commandV1 == BFV1_HELLO);
    assert(payloadRawLenV1 == strlen(messageV1));
    assert(memcmp(payloadRawV1, messageV1, payloadRawLenV1) == 0);

    BFProtocolSetV1Enabled(0);

    printf("test_BFBoxProtocol: OK\n");
    return 0;
}
