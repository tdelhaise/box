#include "box/BFBoxProtocol.h"
#include "box/BFCommon.h"
#include "box/BFDtls.h"
#include "box/BFUdp.h"
#include "box/BFUdpClient.h"

#include <arpa/inet.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

typedef struct ClientDtlsOptions {
    const char *certificateFile;
    const char *keyFile;
    const char *preShareKeyIdentity;
    const char *preShareKeyAscii;
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

    // 2) Handshake DTLS (optional config from CLI)
    BFDtlsConfig         config            = {0};
    const unsigned char *preShareKeyPtr    = NULL;
    size_t               preShareKeyLength = 0;
    if (options.preShareKeyAscii != NULL) {
        preShareKeyPtr    = (const unsigned char *)options.preShareKeyAscii;
        preShareKeyLength = strlen(options.preShareKeyAscii);
    }
    config.certificateFile     = options.certificateFile;
    config.keyFile             = options.keyFile;
    config.preShareKeyIdentity = options.preShareKeyIdentity;
    config.preShareKey         = preShareKeyPtr;
    config.preShareKeyLength   = preShareKeyLength;

    BFDtls *dtls = NULL;
    if (options.certificateFile != NULL || options.keyFile != NULL ||
        options.preShareKeyIdentity != NULL || options.preShareKeyAscii != NULL) {
        dtls = BFDtlsClientNewEx(udpSocket, &config);
    } else {
        dtls = BFDtlsClientNew(udpSocket);
    }
    if (!dtls) {
        BFFatal("dtls_client_new");
    }

    if (BFDtlsHandshakeClient(dtls, (struct sockaddr *)&server, sizeof(server)) != BF_OK) {
        fprintf(stderr, "box: handshake DTLS a échoué (squelette)\n");
        BFDtlsFree(dtls);
        close(udpSocket);
        return 1;
    }

    // 3) Lire HELLO serveur
    uint8_t buffet[BFMaxDatagram];
    int     readCount = BFDtlsRecv(dtls, buffet, (int)sizeof(buffet));
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
        (void)BFDtlsSend(dtls, transmitBuffet, packed);
    }

    // 5) Lire PONG
    readCount = BFDtlsRecv(dtls, buffet, (int)sizeof(buffet));
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

    BFDtlsFree(dtls);
    close(udpSocket);
    return 0;
}
