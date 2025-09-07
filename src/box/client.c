#include "box/box.h"
#include "box/dtls.h"
#include "box/proto.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>

int main(int argc, char **argv) {
    const char *addr = (argc > 1) ? argv[1] : BOX_DEFAULT_ADDR;
    uint16_t port    = (argc > 2) ? (uint16_t)atoi(argv[2]) : BOX_DEFAULT_PORT;

    struct sockaddr_in srv;
    int udp_fd = box_udp_client(addr, port, &srv);
    if (udp_fd < 0) {
        box_fatal("box_udp_client");
    }

    // 1) datagram clair initial
    const char *hello = "hello from box";
    if (box_udp_send(udp_fd, hello, strlen(hello), (struct sockaddr*)&srv, sizeof(srv)) < 0) {
        box_fatal("sendto (hello)");
    }


    // 2) Handshake DTLS
    box_dtls_t *dtls = box_dtls_client_new(udp_fd);
    if (!dtls) {
        box_fatal("dtls_client_new");
    }

    if (box_dtls_handshake_client(dtls, (struct sockaddr*)&srv, sizeof(srv)) != BOX_OK) {
        fprintf(stderr, "box: handshake DTLS a échoué (squelette)\n");
        box_dtls_free(dtls);
        close(udp_fd);
        return 1;
    }

    // 3) Lire HELLO serveur
    uint8_t buf[BOX_MAX_DGRAM];
    int n = box_dtls_recv(dtls, buf, (int)sizeof(buf));
    if (n > 0) {
        box_hdr_t hdr; const uint8_t *payload = NULL;
        if (box_proto_unpack(buf, (size_t)n, &hdr, &payload) > 0 && hdr.type == BOX_MSG_HELLO) {
            BOX_LOG("box: HELLO serveur: %.*s", hdr.length, (const char*)payload);
        } else {
            BOX_LOG("box: premier message non-HELLO ou invalide");
        }
    }

    // 4) Envoyer PING
    uint8_t tx[BOX_MAX_DGRAM];
    const char *ping = "ping";
    int m = box_proto_pack(tx, sizeof(tx), BOX_MSG_PING, ping, (uint16_t)strlen(ping));
    if (m > 0) {
        (void)box_dtls_send(dtls, tx, m);
    }

    // 5) Lire PONG
    n = box_dtls_recv(dtls, buf, (int)sizeof(buf));
    if (n > 0) {
        box_hdr_t hdr; const uint8_t *payload = NULL;
        if (box_proto_unpack(buf, (size_t)n, &hdr, &payload) > 0 && hdr.type == BOX_MSG_PONG) {
            BOX_LOG("box: PONG: %.*s", hdr.length, (const char*)payload);
        } else {
            BOX_LOG("box: réponse inattendue (type=%u)", hdr.type);
        }
    }

    box_dtls_free(dtls);
    close(udp_fd);
    return 0;
}

