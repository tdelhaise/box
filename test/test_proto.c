#include "box/proto.h"
#include <assert.h>
#include <string.h>
#include <stdio.h>

int main(void) {
    uint8_t buf[256];
    const char *msg = "hello";
    int n = box_proto_pack(buf, sizeof(buf), BOX_MSG_HELLO, msg, (uint16_t)strlen(msg));
    assert(n > 0);

    box_hdr_t hdr; const uint8_t *payload = NULL;
    int u = box_proto_unpack(buf, (size_t)n, &hdr, &payload);
    assert(u == n);
    assert(hdr.type == BOX_MSG_HELLO);
    assert(hdr.length == strlen(msg));
    assert(memcmp(payload, msg, hdr.length) == 0);

    printf("test_proto: OK\n");
    return 0;
}

