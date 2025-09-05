#include "box/proto.h"
#include <string.h>
#include <arpa/inet.h>

int box_proto_pack(uint8_t *buf, size_t buflen, box_msg_type_t type, const void *payload, uint16_t len) {
if (buflen < sizeof(box_hdr_t) + len) return -1;

box_hdr_t *hdr = (box_hdr_t*)buf;
hdr->type = htons((uint16_t)type);
hdr->length = htons(len);

if (len && payload)
memcpy(buf + sizeof(box_hdr_t), payload, len);

return sizeof(box_hdr_t) + len;
}

int box_proto_unpack(const uint8_t *buf, size_t buflen, box_hdr_t *hdr, const uint8_t **payload) {
if (buflen < sizeof(box_hdr_t)) return -1;

const box_hdr_t *h = (const box_hdr_t*)buf;
uint16_t len = ntohs(h->length);

if (buflen < sizeof(box_hdr_t) + len) return -1;

if (hdr) {
hdr->type = ntohs(h->type);
hdr->length = len;
}
if (payload) *payload = buf + sizeof(box_hdr_t);

return sizeof(box_hdr_t) + len;
}
