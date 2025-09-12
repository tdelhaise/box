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
            "Usage: %s [address] [port] [--put <queue>[:type] <data>] [--get <queue>]\n"
            "          [--version] [--help]\n\n"
            "Examples:\n"
            "  %s 127.0.0.1 9988 --put /message:text/plain \"Hello\"\n"
            "  %s 127.0.0.1 9988 --get /message\n",
            program, program, program);
}

static void ClientParseArgs(int argc, char **argv, ClientDtlsOptions *outOptions,
                            const char **outAddress, uint16_t *outPort) {
    memset(outOptions, 0, sizeof(*outOptions));
    const char *address = BFDefaultAddress;
    uint16_t    port    = BFDefaultPort;

    for (int argumentIndex = 1; argumentIndex < argc; ++argumentIndex) {
        const char *arg = argv[argumentIndex];
        if (strcmp(arg, "--help") == 0 || strcmp(arg, "-h") == 0) {
            ClientPrintUsage(argv[0]);
            exit(0);
        } else if (strcmp(arg, "--cert") == 0 && argumentIndex + 1 < argc) {
            outOptions->certificateFile = argv[++argumentIndex];
        } else if (strcmp(arg, "--key") == 0 && argumentIndex + 1 < argc) {
            outOptions->keyFile = argv[++argumentIndex];
        } else if (strcmp(arg, "--pre-share-key-identity") == 0 && argumentIndex + 1 < argc) {
            outOptions->preShareKeyIdentity = argv[++argumentIndex];
        } else if (strcmp(arg, "--pre-share-key") == 0 && argumentIndex + 1 < argc) {
            outOptions->preShareKeyAscii = argv[++argumentIndex];
        } else if (strcmp(arg, "--transport") == 0 && argumentIndex + 1 < argc) {
            outOptions->transport = argv[++argumentIndex];
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
    BFLoggerInit("box");
    BFLoggerSetLevel(BF_LOG_INFO);

    struct sockaddr_in server;
    int                udpSocket = BFUdpClient(address, port, &server);
    if (udpSocket < 0) {
        BFFatal("BFUdpClient");
    }

    // 1) Envoyer HELLO (v1) en UDP clair avec versions supportées
    uint8_t  transmitBuffer[BFMaxDatagram];
    uint64_t requestId            = 1;
    uint16_t supportedVersions[1] = {1};
    int packed = BFV1PackHello(transmitBuffer, sizeof(transmitBuffer), requestId, BFV1_STATUS_OK,
                               supportedVersions, 1);
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
            uint8_t  statusCode   = 0xFF;
            uint16_t versions[4]  = {0};
            uint8_t  versionCount = 0;
            if (BFV1UnpackHello(payload, payloadLength, &statusCode, versions,
                                (uint8_t)(sizeof(versions) / sizeof(versions[0])),
                                &versionCount) == 0) {
                int compatible = 0;
                for (uint8_t vi = 0; vi < versionCount; ++vi) {
                    if (versions[vi] == 1) {
                        compatible = 1;
                        break;
                    }
                }
                if (!compatible) {
                    BFLog("box: HELLO serveur sans version compatible (count=%u)",
                          (unsigned)versionCount);
                } else {
                    BFLog("box: HELLO serveur: status=%u versions=%u (compatible)",
                          (unsigned)statusCode, (unsigned)versionCount);
                }
            } else {
                BFLog("box: HELLO serveur avec payload non conforme");
            }
        } else {
            BFLog("box: premier message non-HELLO ou invalide");
        }
    }

    // 4) Envoyer STATUS (ping)
    const char *ping = "ping";
    requestId        = 2;
    packed = BFV1PackStatus(transmitBuffer, sizeof(transmitBuffer), BFV1_STATUS, requestId,
                            BFV1_STATUS_OK, ping);
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
            uint8_t        statusCode     = 0xFF;
            const uint8_t *messagePointer = NULL;
            uint32_t       messageLength  = 0;
            if (BFV1UnpackStatus(payload, payloadLength, &statusCode, &messagePointer,
                                 &messageLength) == 0) {
                BFLog("box: STATUS (pong): status=%u message=%.*s", (unsigned)statusCode,
                      messageLength, (const char *)messagePointer);
            } else {
                BFLog("box: STATUS payload non conforme");
            }
        } else {
            BFLog("box: réponse inattendue (commande=%u)", command);
        }
    }

    // 6) CLI action: PUT/GET if requested
    if (action.doPut && action.queue && action.data) {
        const char *queuePath = action.queue;
        const char *contentType =
            action.contentType ? action.contentType : "application/octet-stream";
        const char *putText = action.data;
        requestId           = 3;
        packed = BFV1PackPut(transmitBuffer, sizeof(transmitBuffer), requestId, queuePath,
                             contentType, (const uint8_t *)putText, (uint32_t)strlen(putText));
        if (packed <= 0 || BFUdpSend(udpSocket, transmitBuffer, (size_t)packed,
                                     (struct sockaddr *)&server, sizeof(server)) < 0) {
            BFFatal("sendto (PUT)");
        }
    } else if (action.doGet && action.queue) {
        requestId = 4;
        packed    = BFV1PackGet(transmitBuffer, sizeof(transmitBuffer), requestId, action.queue);
        if (packed <= 0 || BFUdpSend(udpSocket, transmitBuffer, (size_t)packed,
                                     (struct sockaddr *)&server, sizeof(server)) < 0) {
            BFFatal("sendto (GET)");
        }
        // Read one response and print summary
        fromLen   = sizeof(from);
        readCount = (int)BFUdpRecieve(udpSocket, buffer, sizeof(buffer), &from, &fromLen);
        if (readCount > 0) {
            uint32_t       rcmd       = 0;
            uint64_t       rid        = 0;
            const uint8_t *rpayload   = NULL;
            uint32_t       rpayLength = 0;
            if (BFV1Unpack(buffer, (size_t)readCount, &rcmd, &rid, &rpayload, &rpayLength) > 0) {
                if (rcmd == BFV1_PUT) {
                    const uint8_t *qp = NULL;
                    uint16_t       ql = 0;
                    const uint8_t *ct = NULL;
                    uint16_t       cl = 0;
                    const uint8_t *dd = NULL;
                    uint32_t       dl = 0;
                    if (BFV1UnpackPut(rpayload, rpayLength, &qp, &ql, &ct, &cl, &dd, &dl) == 0) {
                        BFLog("box: GET result queue=%.*s type=%.*s size=%u", (int)ql,
                              (const char *)qp, (int)cl, (const char *)ct, (unsigned)dl);
                    }
                } else if (rcmd == BFV1_STATUS) {
                    uint8_t        sc = 0xFF;
                    const uint8_t *mp = NULL;
                    uint32_t       ml = 0;
                    if (BFV1UnpackStatus(rpayload, rpayLength, &sc, &mp, &ml) == 0) {
                        BFLog("box: GET status=%u message=%.*s", (unsigned)sc, ml,
                              (const char *)mp);
                    }
                }
            }
        }
    }

    close(udpSocket);
    return 0;
}
