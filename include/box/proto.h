#ifndef BOX_PROTO_H
#define BOX_PROTO_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
	BOX_MSG_HELLO = 1,
	BOX_MSG_PING = 2,
	BOX_MSG_PONG = 3,
	BOX_MSG_DATA = 4
} box_msg_type_t;

typedef struct {
	uint16_t type;
	uint16_t length;
} box_hdr_t;

int box_proto_pack(uint8_t *buf, size_t buflen, box_msg_type_t type, const void *payload, uint16_t len);

int box_proto_unpack(const uint8_t *buf, size_t buflen, box_hdr_t *hdr, const uint8_t **payload);

#ifdef __cplusplus
}
#endif

#endif // BOX_PROTO_H
