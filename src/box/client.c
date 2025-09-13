#include "box/BFBoxProtocolV1.h"
#include "box/BFCommon.h"
#include "box/BFMemory.h"
#include "box/BFNetwork.h"
#include "box/BFUdp.h"
#include "box/BFUdpClient.h"
#include "box/BFVersion.h"

#include <arpa/inet.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#if defined(__unix__) || defined(__APPLE__)
#include <sys/un.h>
#endif

typedef struct ClientDtlsOptions {
    const char *certificateFile;
    const char *keyFile;
    const char *preShareKeyIdentity;
    const char *preShareKeyAscii;
    const char *transport;
} ClientDtlsOptions;

typedef struct ClientAction {
    int         doPut;
    int         doGet;
    const char *queue;
    const char *contentType;    // optional
    const char *data;           // for put
    int         queueAllocated; // whether queue was heap-allocated here
} ClientAction;

static void ClientPrintUsage(const char *program) {
    fprintf(stderr,
            "Usage: %s [address] [port] [--port <udp>] [--put <queue>[:type] <data>] [--get <queue>]\n"
            "          [--transport <clear|noise>] [--pre-share-key <ascii>]\n"
            "          [--version] [--help]\n"
            "       | %s admin status    # query local daemon status (Unix)\n\n"
            "Examples:\n"
            "  %s 127.0.0.1 9988 --put /message:text/plain \"Hello\"\n"
            "  %s 127.0.0.1 --port 9988 --get /message\n"
            "  %s --transport noise --pre-share-key devsecret\n"
            "  %s admin status\n",
            program, program, program, program, program, program);
}

static void ClientParseArgs(int argc, char **argv, ClientDtlsOptions *outOptions, const char **outAddress, uint16_t *outPort, const char **outPortOrigin, ClientAction *outAction) {
    memset(outOptions, 0, sizeof(*outOptions));
    memset(outAction, 0, sizeof(*outAction));
    const char *address    = BFGlobalDefaultAddress;
    uint16_t    port       = BFGlobalDefaultPort;
    const char *portOrigin = "default";

    for (int argumentIndex = 1; argumentIndex < argc; ++argumentIndex) {
        const char *arg = argv[argumentIndex];
        if (strcmp(arg, "--help") == 0 || strcmp(arg, "-h") == 0) {
            ClientPrintUsage(argv[0]);
            exit(0);
        } else if (strcmp(arg, "--version") == 0 || strcmp(arg, "-V") == 0) {
            fprintf(stdout, "box %s\n", BFVersionString());
            exit(0);
        } else if (strcmp(arg, "--port") == 0 && argumentIndex + 1 < argc) {
            const char *portValueString = argv[++argumentIndex];
            long        portValue       = strtol(portValueString, NULL, 10);
            if (portValue > 0 && portValue < 65536) {
                port       = (uint16_t)portValue;
                portOrigin = "cli-flag";
            } else {
                BFError("Invalid --port: %s", portValueString);
                exit(2);
            }
        } else if (strcmp(arg, "--put") == 0 && argumentIndex + 2 < argc) {
            outAction->doPut  = 1;
            const char *spec  = argv[++argumentIndex];
            const char *colon = strchr(spec, ':');
            if (colon) {
                size_t queuePathLength = (size_t)(colon - spec);
                char  *queuePath       = (char *)BFMemoryAllocate(queuePathLength + 1U);
                if (queuePath) {
                    memcpy(queuePath, spec, queuePathLength);
                    queuePath[queuePathLength] = '\0';
                    outAction->queue           = queuePath;
                    outAction->queueAllocated  = 1;
                }
                outAction->contentType = colon + 1;
            } else {
                outAction->queue = spec;
            }
            outAction->data = argv[++argumentIndex];
        } else if (strcmp(arg, "--get") == 0 && argumentIndex + 1 < argc) {
            outAction->doGet = 1;
            outAction->queue = argv[++argumentIndex];
        } else if (strcmp(arg, "--transport") == 0 && argumentIndex + 1 < argc) {
            outOptions->transport = argv[++argumentIndex];
        } else if (strcmp(arg, "--pre-share-key") == 0 && argumentIndex + 1 < argc) {
            outOptions->preShareKeyAscii = argv[++argumentIndex];
        } else if (arg[0] != '-') {
            // positional
            if (address == BFGlobalDefaultAddress) {
                address = arg;
            } else {
                long portValue = strtol(arg, NULL, 10);
                if (portValue > 0 && portValue < 65536) {
                    port       = (uint16_t)portValue;
                    portOrigin = "positional";
                } else {
                    BFError("Invalid port: %s", arg);
                    exit(2);
                }
            }
        } else {
            BFError("Unknown option: %s", arg);
            ClientPrintUsage(argv[0]);
            exit(2);
        }
    }

    *outAddress    = address;
    *outPort       = port;
    *outPortOrigin = portOrigin;
}

static int ClientAdminStatus(void) {
#if defined(__unix__) || defined(__APPLE__)
    const char *homeDirectory = getenv("HOME");
    if (!homeDirectory || !*homeDirectory) {
        fprintf(stderr, "box: HOME not set; cannot locate admin socket\n");
        return 2;
    }
    char               socketPath[512];
    struct sockaddr_un address;
    int                clientSocket = -1;
    snprintf(socketPath, sizeof(socketPath), "%s/.box/run/boxd.socket", homeDirectory);
    clientSocket = (int)socket(AF_UNIX, SOCK_STREAM, 0);
    if (clientSocket < 0) {
        perror("socket");
        return 2;
    }
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strncpy(address.sun_path, socketPath, sizeof(address.sun_path) - 1);
    if (connect(clientSocket, (struct sockaddr *)&address, sizeof(address)) != 0) {
        perror("connect");
        close(clientSocket);
        return 2;
    }
    const char *request = "status\n";
    if (write(clientSocket, request, strlen(request)) < 0) {
        perror("write");
        close(clientSocket);
        return 2;
    }
    char    buffer[512];
    ssize_t totalRead = 0;
    for (;;) {
        ssize_t readCount = read(clientSocket, buffer, sizeof(buffer));
        if (readCount <= 0)
            break;
        totalRead += readCount;
        (void)fwrite(buffer, 1U, (size_t)readCount, stdout);
    }
    if (totalRead == 0) {
        fprintf(stderr, "box: empty response from admin channel\n");
    }
    close(clientSocket);
    return 0;
#else
    fprintf(stderr, "box: admin channel not supported on this platform\n");
    return 2;
#endif
}

int main(int argc, char **argv) {
    if (argc >= 3 && strcmp(argv[1], "admin") == 0 && strcmp(argv[2], "status") == 0) {
        return ClientAdminStatus();
    }
    ClientDtlsOptions options;
    ClientAction      action;
    const char       *address    = NULL;
    uint16_t          port       = 0;
    const char       *portOrigin = NULL;
    ClientParseArgs(argc, argv, &options, &address, &port, &portOrigin, &action);
    BFLoggerInit("box");
    BFLoggerSetLevel(BF_LOG_INFO);

    // Log startup parameters (no secrets in client CLI yet)
    char targetName[256] = {0};
    BFLoggerGetTarget(targetName, sizeof(targetName));
    const char *levelName = BFLoggerLevelName(BFLoggerGetLevel());
    if (action.doPut && action.queue && action.data) {
        const char *contentType = action.contentType ? action.contentType : "application/octet-stream";
        size_t      dataSize    = strlen(action.data);
        BFLog("box: start address=%s port=%u portOrigin=%s action=put queue=%s type=%s size=%zu "
              "logLevel=%s logTarget=%s",
              address, (unsigned)port, portOrigin, action.queue, contentType, dataSize, levelName, targetName);
    } else if (action.doGet && action.queue) {
        BFLog("box: start address=%s port=%u portOrigin=%s action=get queue=%s logLevel=%s "
              "logTarget=%s",
              address, (unsigned)port, portOrigin, action.queue, levelName, targetName);
    } else {
        BFLog("box: start address=%s port=%u portOrigin=%s action=handshake transport=%s logLevel=%s "
              "logTarget=%s",
              address, (unsigned)port, portOrigin, (options.transport ? options.transport : "clear"), levelName, targetName);
    }

    struct sockaddr_in server;
    int                udpSocket = BFUdpClient(address, port, &server);
    if (udpSocket < 0) {
        BFFatal("BFUdpClient");
    }

    // 1) Envoyer HELLO (v1) en UDP clair avec versions supportées
    uint8_t  transmitBuffer[BF_MACRO_MAX_DATAGRAM_SIZE];
    uint64_t requestId            = 1;
    uint16_t supportedVersions[1] = {1};
    int      packed               = BFV1PackHello(transmitBuffer, sizeof(transmitBuffer), requestId, BFV1_STATUS_OK, supportedVersions, 1);
    if (packed <= 0 || BFUdpSend(udpSocket, transmitBuffer, (size_t)packed, (struct sockaddr *)&server, sizeof(server)) < 0) {
        BFFatal("sendto (HELLO)");
    }

    // 3) Lire HELLO serveur (v1)
    uint8_t         buffer[BF_MACRO_MAX_DATAGRAM_SIZE];
    struct sockaddr from       = {0};
    socklen_t       fromLength = sizeof(from);
    int             readCount  = (int)BFUdpRecieve(udpSocket, buffer, sizeof(buffer), &from, &fromLength);
    if (readCount > 0) {
        uint32_t       command       = 0;
        uint64_t       requestId     = 0;
        const uint8_t *payload       = NULL;
        uint32_t       payloadLength = 0;
        if (BFV1Unpack(buffer, (size_t)readCount, &command, &requestId, &payload, &payloadLength) > 0 && command == BFV1_HELLO) {
            uint8_t  statusCode   = 0xFF;
            uint16_t versions[4]  = {0};
            uint8_t  versionCount = 0;
            if (BFV1UnpackHello(payload, payloadLength, &statusCode, versions, (uint8_t)(sizeof(versions) / sizeof(versions[0])), &versionCount) == 0) {
                int compatible = 0;
                for (uint8_t versionIndex = 0; versionIndex < versionCount; ++versionIndex) {
                    if (versions[versionIndex] == 1) {
                        compatible = 1;
                        break;
                    }
                }
                if (!compatible) {
                    BFLog("box: HELLO serveur sans version compatible (count=%u)", (unsigned)versionCount);
                } else {
                    BFLog("box: HELLO serveur: status=%u versions=%u (compatible)", (unsigned)statusCode, (unsigned)versionCount);
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
    packed           = BFV1PackStatus(transmitBuffer, sizeof(transmitBuffer), BFV1_STATUS, requestId, BFV1_STATUS_OK, ping);
    if (packed <= 0 || BFUdpSend(udpSocket, transmitBuffer, (size_t)packed, (struct sockaddr *)&server, sizeof(server)) < 0) {
        BFFatal("sendto (STATUS)");
    }

    // 5) Lire réponse STATUS (pong)
    fromLength = sizeof(from);
    readCount  = (int)BFUdpRecieve(udpSocket, buffer, sizeof(buffer), &from, &fromLength);
    if (readCount > 0) {
        uint32_t       command       = 0;
        uint64_t       requestId     = 0;
        const uint8_t *payload       = NULL;
        uint32_t       payloadLength = 0;
        if (BFV1Unpack(buffer, (size_t)readCount, &command, &requestId, &payload, &payloadLength) > 0 && command == BFV1_STATUS) {
            uint8_t        statusCode     = 0xFF;
            const uint8_t *messagePointer = NULL;
            uint32_t       messageLength  = 0;
            if (BFV1UnpackStatus(payload, payloadLength, &statusCode, &messagePointer, &messageLength) == 0) {
                BFLog("box: STATUS (pong): status=%u message=%.*s", (unsigned)statusCode, messageLength, (const char *)messagePointer);
            } else {
                BFLog("box: STATUS payload non conforme");
            }
        } else {
            BFLog("box: réponse inattendue (commande=%u)", command);
        }
    }

    // 6) CLI action: PUT/GET if requested
    if (action.doPut && action.queue && action.data) {
        const char *queuePath   = action.queue;
        const char *contentType = action.contentType ? action.contentType : "application/octet-stream";
        const char *putText     = action.data;
        requestId               = 3;
        packed                  = BFV1PackPut(transmitBuffer, sizeof(transmitBuffer), requestId, queuePath, contentType, (const uint8_t *)putText, (uint32_t)strlen(putText));
        if (packed <= 0 || BFUdpSend(udpSocket, transmitBuffer, (size_t)packed, (struct sockaddr *)&server, sizeof(server)) < 0) {
            BFFatal("sendto (PUT)");
        }
    } else if (action.doGet && action.queue) {
        requestId = 4;
        packed    = BFV1PackGet(transmitBuffer, sizeof(transmitBuffer), requestId, action.queue);
        if (packed <= 0 || BFUdpSend(udpSocket, transmitBuffer, (size_t)packed, (struct sockaddr *)&server, sizeof(server)) < 0) {
            BFFatal("sendto (GET)");
        }
        // Read one response and print summary
        fromLength = sizeof(from);
        readCount  = (int)BFUdpRecieve(udpSocket, buffer, sizeof(buffer), &from, &fromLength);
        if (readCount > 0) {
            uint32_t       responseCommand       = 0;
            uint64_t       responseRequestId     = 0;
            const uint8_t *responsePayload       = NULL;
            uint32_t       responsePayloadLength = 0;
            if (BFV1Unpack(buffer, (size_t)readCount, &responseCommand, &responseRequestId, &responsePayload, &responsePayloadLength) > 0) {
                if (responseCommand == BFV1_PUT) {
                    const uint8_t *queuePathPointer   = NULL;
                    uint16_t       queuePathLength    = 0;
                    const uint8_t *contentTypePointer = NULL;
                    uint16_t       contentTypeLength  = 0;
                    const uint8_t *dataPointer        = NULL;
                    uint32_t       dataLength         = 0;
                    if (BFV1UnpackPut(responsePayload, responsePayloadLength, &queuePathPointer, &queuePathLength, &contentTypePointer, &contentTypeLength, &dataPointer, &dataLength) == 0) {
                        BFLog("box: GET result queue=%.*s type=%.*s size=%u", (int)queuePathLength, (const char *)queuePathPointer, (int)contentTypeLength, (const char *)contentTypePointer, (unsigned)dataLength);
                    }
                } else if (responseCommand == BFV1_STATUS) {
                    uint8_t        statusCode     = 0xFF;
                    const uint8_t *messagePointer = NULL;
                    uint32_t       messageLength  = 0;
                    if (BFV1UnpackStatus(responsePayload, responsePayloadLength, &statusCode, &messagePointer, &messageLength) == 0) {
                        BFLog("box: GET status=%u message=%.*s", (unsigned)statusCode, messageLength, (const char *)messagePointer);
                    }
                }
            }
        }
    }

    if (action.queueAllocated && action.queue) {
        BFMemoryRelease((void *)action.queue);
    }

    // Noise transport smoke test if requested
    if (options.transport && strcmp(options.transport, "noise") == 0) {
        BFNetworkSecurity security = {0};
        if (options.preShareKeyAscii) {
            security.preShareKey       = (const unsigned char *)options.preShareKeyAscii;
            security.preShareKeyLength = (size_t)strlen(options.preShareKeyAscii);
        }
        // Accept environment override for pattern (scaffold)
        const char *patternEnvironment = getenv("BOX_NOISE_PATTERN");
        if (patternEnvironment && *patternEnvironment) {
            security.hasNoiseHandshakePattern = 1;
            if (strcmp(patternEnvironment, "nk") == 0) {
                security.noiseHandshakePattern = BFNoiseHandshakePatternNK;
            } else if (strcmp(patternEnvironment, "ik") == 0) {
                security.noiseHandshakePattern = BFNoiseHandshakePatternIK;
            } else {
                security.hasNoiseHandshakePattern = 0;
            }
        }
        BFNetworkConnection *nc = BFNetworkConnectDatagram(BFNetworkTransportNOISE, udpSocket, (struct sockaddr *)&server, sizeof(server), &security);
        if (!nc) {
            BFFatal("BFNetworkConnectDatagram(noise)");
        }
        const char *pingText = "ping";
        if (BFNetworkSend(nc, pingText, (int)strlen(pingText)) <= 0) {
            BFFatal("noise send");
        }
        char reply[256];
        int  rr = BFNetworkRecv(nc, reply, (int)sizeof(reply));
        if (rr > 0) {
            BFLog("box(noise): reply %.*s", rr, reply);
        }
        BFNetworkClose(nc);
        close(udpSocket);
        return 0;
    }

    close(udpSocket);
    return 0;
}
