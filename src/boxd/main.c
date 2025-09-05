#include "box/box.h"
#include "box/dtls.h"
#include "box/proto.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <signal.h>

static volatile int g_running = 1;
static void on_sigint(int sig){ (void)sig; g_running = 0; }

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    signal(SIGINT, on_sigint);

    int udp_fd = box_udp_server(BOX_DEFAULT_PORT);
    if (udp_fd < 0) box_fatal("box_udp_server");

    // 1) Attente d'un datagram clair pour connaître l'adresse du client
    struct sockaddr_storage peer = {0};
    socklen_t peerlen = sizeof(peer);
    uint8_t rxbuf[BOX_MAX_DGRAM];

    ssize_t r = box_udp_recv(udp_fd, rxbuf, sizeof(rxbuf), (struct sockaddr*)&peer, &peerlen);
    if (r < 0) box_fatal("recvfrom (hello)");
    BOX_LOG("boxd: datagram initial %zd octets reçu — handshake DTLS…", r);

    // 2) Handshake DTLS
    box_dtls_t *dtls = box_dtls_server_new(udp_fd);
    if (!dtls) box_fatal("dtls_server_new");

    if (box_dtls_handshake_server(dtls, &peer, peerlen) != BOX_OK) {
        fprintf(stderr, "boxd: handshake DTLS a échoué (squelette)\n");
        box_dtls_free(dtls);
        close(udp_fd);
        return 1;
    }

    // 3) Envoi d'un HELLO applicatif via DTLS
    uint8_t txbuf[BOX_MAX_DGRAM];
    const char *hello_payload = "hello from boxd";
    int m = box_proto_pack(txbuf, sizeof(txbuf), BOX_MSG_HELLO,
                           hello_payload, (uint16_t)strlen(hello_payload));
    if (m > 0) (void)box_dtls_send(dtls, txbuf, m);

    // 4) Boucle simple: attendre PING et répondre PONG
    while (g_running) {
        int n = box_dtls_recv(dtls, rxbuf, (int)sizeof(rxbuf));
        if (n <= 0) {
            // TODO: gérer WANT_READ/WRITE, timeouts, retransmissions
            break;
        }
        box_hdr_t hdr; const uint8_t *payload = NULL;
        int u = box_proto_unpack(rxbuf, (size_t)n, &hdr, &payload);
        if (u < 0) {
            BOX_LOG("boxd: trame invalide");
            continue;
        }
        switch (hdr.type) {
            case BOX_MSG_PING: {
                BOX_LOG("boxd: PING reçu (%u octets)", hdr.length);
                const char *pong = "pong";
                int k = box_proto_pack(txbuf, sizeof(txbuf), BOX_MSG_PONG,
                                       pong, (uint16_t)strlen(pong));
                if (k > 0) (void)box_dtls_send(dtls, txbuf, k);
                break;
            }
            case BOX_MSG_DATA: {
                BOX_LOG("boxd: DATA %u octets", hdr.length);
                break;
            }
            default:
                BOX_LOG("boxd: type inconnu: %u", hdr.type);
                break;
        }
    }

    box_dtls_free(dtls);
    close(udp_fd);
    return 0;
}

