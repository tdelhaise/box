#include "box/protocol.h"
#include <assert.h>
#include <string.h>
#include <stdio.h>

int main(void) {
    uint8_t buffet[256];
    const char *message = "hello";
    int packed = BFProtocolPack(buffet, sizeof(buffet), BFMessageHello, message, (uint16_t)strlen(message));
    assert(packed > 0);

    BFHeader header; const uint8_t *payload = NULL;
    int unpacked = BFProtocolUnpack(buffet, (size_t)packed, &header, &payload);
    assert(unpacked == packed);
    assert(header.type == BFMessageHello);
    assert(header.length == strlen(message));
    assert(memcmp(payload, message, header.length) == 0);

    printf("test_protocol: OK\n");
    return 0;
}

