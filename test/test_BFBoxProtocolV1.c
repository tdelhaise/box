#include "box/BFBoxProtocolV1.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    uint8_t buffer[256];
    const char *message = "hello";
    uint32_t command = BFV1_PUT;
    uint64_t requestId = 0x1122334455667788ULL;

    int packed = BFV1Pack(buffer, sizeof(buffer), command, requestId, message, (uint32_t)strlen(message));
    assert(packed > 0);

    uint32_t outCommand = 0;
    uint64_t outRequestId = 0;
    const uint8_t *outPayload = NULL;
    uint32_t outPayloadLength = 0;
    int unpacked = BFV1Unpack(buffer, (size_t)packed, &outCommand, &outRequestId, &outPayload, &outPayloadLength);
    assert(unpacked == packed);
    assert(outCommand == command);
    assert(outRequestId == requestId);
    assert(outPayload != NULL);
    assert(outPayloadLength == strlen(message));
    assert(memcmp(outPayload, message, outPayloadLength) == 0);

    printf("BFBoxProtocolV1 OK\n");
    return 0;
}

