#include "box/BFBoxProtocol.h"
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

    BFNetworkConnection *conn = BFNetworkConnectDatagram(transport, udpSocket,
                                                         (struct sockaddr *)&server,
                                                         sizeof(server), &sec);
    if (!conn) {
        fprintf(stderr, "box: handshake/connection failed\n");
        close(udpSocket);
        return 1;
    }

    // 3) Lire HELLO serveur
    uint8_t buffet[BFMaxDatagram];
    int     readCount = BFNetworkRecv(conn, buffet, (int)sizeof(buffet));
    if (readCount > 0) {
        BFHeader       header;
        const uint8_t *payload = NULL;
        if (BFProtocolUnpack(buffet, (size_t)readCount, &header, &payload) > 0 &&
            header.type == BFMessageHello) {
            BFLog("box: HELLO serveur: %.*s", header.length, (const char *)payload);
        } else {
            BFLog("box: premier message non-HELLO ou invalide");
        }
    }

    // 4) Envoyer PING
    uint8_t     transmitBuffet[BFMaxDatagram];
    const char *ping   = "ping";
    int         packed = BFProtocolPack(transmitBuffet, sizeof(transmitBuffet), BFMessagePing, ping,
                                        (uint16_t)strlen(ping));
    if (packed > 0) {
        (void)BFNetworkSend(conn, transmitBuffet, packed);
    }

    // 5) Lire PONG
    readCount = BFNetworkRecv(conn, buffet, (int)sizeof(buffet));
    if (readCount > 0) {
        BFHeader       header;
        const uint8_t *payload = NULL;
        if (BFProtocolUnpack(buffet, (size_t)readCount, &header, &payload) > 0 &&
            header.type == BFMessagePong) {
            BFLog("box: PONG: %.*s", header.length, (const char *)payload);
        } else {
            BFLog("box: réponse inattendue (type=%u)", header.type);
        }
    }

    BFNetworkClose(conn);
    close(udpSocket);
    return 0;
}
