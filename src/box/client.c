#include "box/BFCommon.h"
#include "box/BFUdp.h"
#include "box/BFUdpClient.h"
#include "box/BFDtls.h"
#include "box/BFBoxProtocol.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>

int main(int argc, char **argv) {
    const char *address = (argc > 1) ? argv[1] : BFDefaultAddress;
    uint16_t port    = (argc > 2) ? (uint16_t)atoi(argv[2]) : BFDefaultPort;

    struct sockaddr_in server;
    int udpSocket = BFUdpClient(address, port, &server);
    if (udpSocket < 0) {
        BFFatal("BFUdpClient");
    }

    // 1) datagram clair initial
    const char *hello = "hello from box";
    if (BFUdpSend(udpSocket, hello, strlen(hello), (struct sockaddr*)&server, sizeof(server)) < 0) {
        BFFatal("sendto (hello)");
    }


    // 2) Handshake DTLS
    BFDtls *dtls = BFDtlsClientNew(udpSocket);
    if (!dtls) {
        BFFatal("dtls_client_new");
    }

    if (BFDtlsHandshakeClient(dtls, (struct sockaddr*)&server, sizeof(server)) != BF_OK) {
        fprintf(stderr, "box: handshake DTLS a échoué (squelette)\n");
        BFDtlsFree(dtls);
        close(udpSocket);
        return 1;
    }

    // 3) Lire HELLO serveur
    uint8_t buffet[BFMaxDatagram];
    int readCount = BFDtlsRecv(dtls, buffet, (int)sizeof(buffet));
    if (readCount > 0) {
        BFHeader header; const uint8_t *payload = NULL;
        if (BFProtocolUnpack(buffet, (size_t)readCount, &header, &payload) > 0 && header.type == BFMessageHello) {
            BFLog("box: HELLO serveur: %.*s", header.length, (const char*)payload);
        } else {
            BFLog("box: premier message non-HELLO ou invalide");
        }
    }

    // 4) Envoyer PING
    uint8_t transmitBuffet[BFMaxDatagram];
    const char *ping = "ping";
    int packed = BFProtocolPack(transmitBuffet, sizeof(transmitBuffet), BFMessagePing, ping, (uint16_t)strlen(ping));
    if (packed > 0) {
        (void)BFDtlsSend(dtls, transmitBuffet, packed);
    }

    // 5) Lire PONG
    readCount = BFDtlsRecv(dtls, buffet, (int)sizeof(buffet));
    if (readCount > 0) {
        BFHeader header; const uint8_t *payload = NULL;
        if (BFProtocolUnpack(buffet, (size_t)readCount, &header, &payload) > 0 && header.type == BFMessagePong) {
            BFLog("box: PONG: %.*s", header.length, (const char*)payload);
        } else {
            BFLog("box: réponse inattendue (type=%u)", header.type);
        }
    }

    BFDtlsFree(dtls);
    close(udpSocket);
    return 0;
}
