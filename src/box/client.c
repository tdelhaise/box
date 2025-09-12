#include "box/BFBoxProtocolV1.h"
#include "box/BFCommon.h"
#include "box/BFUdp.h"
#include "box/BFUdpClient.h"

#include <arpa/inet.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

typedef struct ClientDtlsOptions {
    const char *certificateFile;
    const char *keyFile;
    const char *preShareKeyIdentity;
    const char *preShareKeyAscii;
    const char *transport;
} ClientDtlsOptions;

static void ClientPrintUsage(const char *program) {
    fprintf(stderr,
            "Usage: %s [--cert <pem>] [--key <pem>] [--pre-share-key-identity <id>]\n"
            "          [--pre-share-key <ascii>] [address] [port]\n",
            program);
}

static void ClientParseArgs(int argc, char **argv, ClientDtlsOptions *outOptions,
                            const char **outAddress, uint16_t *outPort) {
    memset(outOptions, 0, sizeof(*outOptions));
    const char *address = BFDefaultAddress;
    uint16_t    port    = BFDefaultPort;

    for (int i = 1; i < argc; ++i) {
        const char *arg = argv[i];
        if (strcmp(arg, "--help") == 0 || strcmp(arg, "-h") == 0) {
            ClientPrintUsage(argv[0]);
            exit(0);
        } else if (strcmp(arg, "--cert") == 0 && i + 1 < argc) {
            outOptions->certificateFile = argv[++i];
        } else if (strcmp(arg, "--key") == 0 && i + 1 < argc) {
            outOptions->keyFile = argv[++i];
        } else if (strcmp(arg, "--pre-share-key-identity") == 0 && i + 1 < argc) {
            outOptions->preShareKeyIdentity = argv[++i];
        } else if (strcmp(arg, "--pre-share-key") == 0 && i + 1 < argc) {
            outOptions->preShareKeyAscii = argv[++i];
        } else if (strcmp(arg, "--transport") == 0 && i + 1 < argc) {
            outOptions->transport = argv[++i];
        } else if (arg[0] != '-') {
            // positional
            if (address == BFDefaultAddress) {
                address = arg;
            } else {
                port = (uint16_t)atoi(arg);
            }
        } else {
            BFError("Unknown option: %s", arg);
            ClientPrintUsage(argv[0]);
            exit(2);
        }
    }

    *outAddress = address;
    *outPort    = port;
}

int main(int argc, char **argv) {
    ClientDtlsOptions options;
    const char       *address = NULL;
    uint16_t          port    = 0;
    ClientParseArgs(argc, argv, &options, &address, &port);

    struct sockaddr_in server;
    int                udpSocket = BFUdpClient(address, port, &server);
    if (udpSocket < 0) {
        BFFatal("BFUdpClient");
    }

    // 1) Envoyer HELLO (v1) en UDP clair
    uint8_t     transmitBuffer[BFMaxDatagram];
    const char *hello     = "hello from box";
    uint64_t    requestId = 1;
    int packed = BFV1Pack(transmitBuffer, sizeof(transmitBuffer), BFV1_HELLO, requestId, hello,
                          (uint32_t)strlen(hello));
    if (packed <= 0 || BFUdpSend(udpSocket, transmitBuffer, (size_t)packed,
                                 (struct sockaddr *)&server, sizeof(server)) < 0) {
        BFFatal("sendto (HELLO)");
    }

    // 3) Lire HELLO serveur (v1)
    uint8_t         buffer[BFMaxDatagram];
    struct sockaddr from    = {0};
    socklen_t       fromLen = sizeof(from);
    int readCount           = (int)BFUdpRecieve(udpSocket, buffer, sizeof(buffer), &from, &fromLen);
    if (readCount > 0) {
        uint32_t       command       = 0;
        uint64_t       requestId     = 0;
        const uint8_t *payload       = NULL;
        uint32_t       payloadLength = 0;
        if (BFV1Unpack(buffer, (size_t)readCount, &command, &requestId, &payload, &payloadLength) >
                0 &&
            command == BFV1_HELLO) {
            BFLog("box: HELLO serveur: %.*s", payloadLength, (const char *)payload);
        } else {
            BFLog("box: premier message non-HELLO ou invalide");
        }
    }

    // 4) Envoyer STATUS (ping)
    const char *ping = "ping";
    requestId        = 2;
    packed = BFV1Pack(transmitBuffer, sizeof(transmitBuffer), BFV1_STATUS, requestId, ping,
                      (uint32_t)strlen(ping));
    if (packed <= 0 || BFUdpSend(udpSocket, transmitBuffer, (size_t)packed,
                                 (struct sockaddr *)&server, sizeof(server)) < 0) {
        BFFatal("sendto (STATUS)");
    }

    // 5) Lire réponse STATUS (pong)
    fromLen   = sizeof(from);
    readCount = (int)BFUdpRecieve(udpSocket, buffer, sizeof(buffer), &from, &fromLen);
    if (readCount > 0) {
        uint32_t       command       = 0;
        uint64_t       requestId     = 0;
        const uint8_t *payload       = NULL;
        uint32_t       payloadLength = 0;
        if (BFV1Unpack(buffer, (size_t)readCount, &command, &requestId, &payload, &payloadLength) >
                0 &&
            command == BFV1_STATUS) {
            BFLog("box: STATUS (pong): %.*s", payloadLength, (const char *)payload);
        } else {
            BFLog("box: réponse inattendue (commande=%u)", command);
        }
    }

    close(udpSocket);
    return 0;
}
