#include "box/BFCommon.h"
#include "box/BFUdp.h"
#include "box/BFUdpServer.h"
#include "box/dtls.h"
#include "box/protocol.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <signal.h>

static volatile int g_running = 1;
static void on_sigint(int sig) {
    (void)sig;
    g_running = 0;
    BFLog("boxd: Interupt signal received. Exiting.");
    exit(-sig);
}

void install_signal_handler(void) {
    signal(SIGINT, on_sigint);
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    install_signal_handler();

    int udpSocket = BFUdpServer(BFDefaultPort);
    if (udpSocket < 0) {
        BFFatal("BFUdpServer");
    }

    // 1) Attente d'un datagram clair pour connaître l'adresse du client
    struct sockaddr_storage peer = {0};
    socklen_t peerLength = sizeof(peer);
    uint8_t receiveBuffer[BFMaxDatagram];

    memset(receiveBuffer, 0, sizeof(receiveBuffer));

    ssize_t received = BFUdpRecieve(udpSocket, receiveBuffer, sizeof(receiveBuffer), (struct sockaddr*)&peer, &peerLength);
    if (received < 0) {
        BFFatal("recvfrom (hello)");
    }

    BFLog("boxd: datagram initial %zd octets reçu — %s", received, (char*) receiveBuffer);

    // 2) Handshake DTLS
    BFDtls *dtls = BFDtlsServerNew(udpSocket);
    if (!dtls) {
        BFFatal("dtls_server_new");
    }

    if (BFDtlsHandshakeServer(dtls, &peer, peerLength) != BF_OK) {
        fprintf(stderr, "boxd: handshake DTLS a échoué (squelette)\n");
        BFDtlsFree(dtls);
        close(udpSocket);
        return 1;
    }

    // 3) Envoi d'un HELLO applicatif via DTLS
    uint8_t transmitBuffer[BFMaxDatagram];
    const char *helloPayload = "hello from boxd";

    int packed = BFProtocolPack(transmitBuffer, sizeof(transmitBuffer), BFMessageHello, helloPayload, (uint16_t)strlen(helloPayload));
    if (packed > 0)
        (void)BFDtlsSend(dtls, transmitBuffer, packed);

    // 4) Boucle simple: attendre PING et répondre PONG
    while (g_running) {
        int readCount = BFDtlsRecv(dtls, receiveBuffer, (int)sizeof(receiveBuffer));
        if (readCount <= 0) {
            // TODO: gérer WANT_READ/WRITE, timeouts, retransmissions
            break;
        }
        BFHeader header; const uint8_t *payload = NULL;
        int unpacked = BFProtocolUnpack(receiveBuffer, (size_t)readCount, &header, &payload);
        if (unpacked < 0) {
            BFLog("boxd: trame invalide");
            continue;
        }
        switch (header.type) {
            case BFMessagePing: {
                BFLog("boxd: PING reçu (%u octets)", header.length);
                const char *pong = "pong";
                int k = BFProtocolPack(transmitBuffer, sizeof(transmitBuffer), BFMessagePong, pong, (uint16_t)strlen(pong));
                if (k > 0)
                        (void)BFDtlsSend(dtls, transmitBuffer, k);
                break;
            }
            case BFMessageData: {
                BFLog("boxd: DATA %u octets", header.length);
                break;
            }
            default: {
                BFLog("boxd: type inconnu: %u", header.type);
                break;
            }
        }
    }

    BFDtlsFree(dtls);
    close(udpSocket);
    return 0;
}

