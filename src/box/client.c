#include "box/BFBoxProtocolV1.h"
#include "box/BFCommon.h"
#include "box/BFNetwork.h"
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

    // 1) datagram clair initial
    const char *hello = "hello from box";
    if (BFUdpSend(udpSocket, hello, strlen(hello), (struct sockaddr *)&server, sizeof(server)) <
        0) {
        BFFatal("sendto (hello)");
    }

    // 2) Handshake secure transport via BFNetwork (DTLS backend in M1)
    BFNetworkSecurity    sec               = {0};
    const unsigned char *preShareKeyPtr    = NULL;
    size_t               preShareKeyLength = 0;
    if (options.preShareKeyAscii != NULL) {
        preShareKeyPtr    = (const unsigned char *)options.preShareKeyAscii;
        preShareKeyLength = strlen(options.preShareKeyAscii);
    }
    sec.certificateFile     = options.certificateFile;
    sec.keyFile             = options.keyFile;
    sec.preShareKeyIdentity = options.preShareKeyIdentity;
    sec.preShareKey         = preShareKeyPtr;
    sec.preShareKeyLength   = preShareKeyLength;
    sec.alpn                = "box/1";

    BFNetworkTransport transport = BFNetworkTransportDTLS;
    if (options.transport && strcmp(options.transport, "quic") == 0)
        transport = BFNetworkTransportQUIC;

    BFNetworkConnection *conn = BFNetworkConnectDatagram(
        transport, udpSocket, (struct sockaddr *)&server, sizeof(server), &sec);
    if (!conn) {
        fprintf(stderr, "box: handshake/connection failed\n");
        close(udpSocket);
        return 1;
    }

    // 3) Lire HELLO serveur (v1)
    uint8_t buffer[BFMaxDatagram];
    int     readCount = BFNetworkRecv(conn, buffer, (int)sizeof(buffer));
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
    uint8_t     transmitBuffer[BFMaxDatagram];
    const char *ping      = "ping";
    uint64_t    requestId = 2;
    int packed = BFV1Pack(transmitBuffer, sizeof(transmitBuffer), BFV1_STATUS, requestId, ping,
                          (uint32_t)strlen(ping));
    if (packed > 0) {
        (void)BFNetworkSend(conn, transmitBuffer, packed);
    }

    // 5) Lire réponse STATUS (pong)
    readCount = BFNetworkRecv(conn, buffer, (int)sizeof(buffer));
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

    BFNetworkClose(conn);
    close(udpSocket);
    return 0;
}
