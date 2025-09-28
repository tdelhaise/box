#include "BFBoxProtocol.h"
#include "BFBoxProtocolV1.h"
#include "BFCommon.h"
#include "BFConfig.h"
#include "BFMemory.h"
#include "BFNetwork.h"
#include "BFRunloop.h"
#include "BFSharedDictionary.h"
#include "BFUdp.h"
#include "BFUdpServer.h"
#include "BFVersion.h"
#include "ServerEventType.h"
#include "ServerAdmin.h"
#include "ServerNetworkInput.h"
#include "ServerNetworkOutput.h"
#include "ServerRuntime.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#if defined(__unix__) || defined(__APPLE__)
#include <pthread.h>
#endif
#include <pwd.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

typedef struct ServerNetworkOptions {
    const char *certificateFile;
    const char *keyFile;
    const char *preShareKeyIdentity;
    const char *preShareKeyAscii;
    const char *transport;
    const char *protocol;
    uint16_t    port; // optional CLI override
    int         hasLogLevel;
    BFLogLevel  commandLineLogLevel;
    int         hasLogTarget;
    char        commandLineLogTarget[128];
} ServerNetworkOptions;

// Simple in-memory object for demo GET/PUT
typedef struct StoredObject {
    char    *contentType;
    uint8_t *data;
    uint32_t dataLength;
} StoredObject;


static void destroyStoredObjectCallback(void *pointer) {
    if (!pointer)
        return;
    StoredObject *object = (StoredObject *)pointer;
    if (object->contentType)
        BFMemoryRelease(object->contentType);
    if (object->data)
        BFMemoryRelease(object->data);
    BFMemoryRelease(object);
}

ServerNetworkDatagram *ServerNetworkDatagramCreate(const uint8_t *datagramBytes,
                                                   size_t         datagramLength,
                                                   const struct sockaddr_storage *peerAddress,
                                                   socklen_t      peerAddressLength) {
    ServerNetworkDatagram *datagram = (ServerNetworkDatagram *)BFMemoryAllocate(sizeof(ServerNetworkDatagram));
    if (!datagram) {
        return NULL;
    }
    memset(datagram, 0, sizeof(ServerNetworkDatagram));
    if (peerAddress && peerAddressLength > 0) {
        datagram->peerAddress       = *peerAddress;
        datagram->peerAddressLength = peerAddressLength;
    }
    datagram->datagramLength = datagramLength;
    if (datagramLength > 0) {
        datagram->datagramBytes = (uint8_t *)BFMemoryAllocate(datagramLength);
        if (!datagram->datagramBytes) {
            BFMemoryRelease(datagram);
            return NULL;
        }
        memcpy(datagram->datagramBytes, datagramBytes, datagramLength);
    } else {
        datagram->datagramBytes = NULL;
    }
    return datagram;
}

void ServerNetworkDatagramDestroy(void *payloadPointer) {
    if (!payloadPointer) {
        return;
    }
    ServerNetworkDatagram *datagram = (ServerNetworkDatagram *)payloadPointer;
    if (datagram->datagramBytes) {
        BFMemoryRelease(datagram->datagramBytes);
        datagram->datagramBytes = NULL;
    }
    BFMemoryRelease(datagram);
}

ServerNetworkSendRequest *ServerNetworkSendRequestCreate(const uint8_t *payloadBytes,
                                                         size_t         payloadLength,
                                                         const struct sockaddr_storage *peerAddress,
                                                         socklen_t      peerAddressLength) {
    ServerNetworkSendRequest *sendRequest = (ServerNetworkSendRequest *)BFMemoryAllocate(sizeof(ServerNetworkSendRequest));
    if (!sendRequest) {
        return NULL;
    }
    memset(sendRequest, 0, sizeof(ServerNetworkSendRequest));
    if (peerAddress && peerAddressLength > 0) {
        sendRequest->peerAddress       = *peerAddress;
        sendRequest->peerAddressLength = peerAddressLength;
    }
    sendRequest->payloadLength = payloadLength;
    if (payloadLength > 0) {
        sendRequest->payloadBytes = (uint8_t *)BFMemoryAllocate(payloadLength);
        if (!sendRequest->payloadBytes) {
            BFMemoryRelease(sendRequest);
            return NULL;
        }
        memcpy(sendRequest->payloadBytes, payloadBytes, payloadLength);
    } else {
        sendRequest->payloadBytes = NULL;
    }
    return sendRequest;
}

void ServerNetworkSendRequestDestroy(void *payloadPointer) {
    if (!payloadPointer) {
        return;
    }
    ServerNetworkSendRequest *sendRequest = (ServerNetworkSendRequest *)payloadPointer;
    if (sendRequest->payloadBytes) {
        BFMemoryRelease(sendRequest->payloadBytes);
        sendRequest->payloadBytes = NULL;
    }
    BFMemoryRelease(sendRequest);
}

ServerNoisePlaintext *ServerNoisePlaintextCreate(const uint8_t *messageBytes, size_t messageLength) {
    ServerNoisePlaintext *plaintext = (ServerNoisePlaintext *)BFMemoryAllocate(sizeof(ServerNoisePlaintext));
    if (!plaintext) {
        return NULL;
    }
    memset(plaintext, 0, sizeof(ServerNoisePlaintext));
    plaintext->messageLength = messageLength;
    if (messageLength > 0) {
        plaintext->messageBytes = (uint8_t *)BFMemoryAllocate(messageLength);
        if (!plaintext->messageBytes) {
            BFMemoryRelease(plaintext);
            return NULL;
        }
        memcpy(plaintext->messageBytes, messageBytes, messageLength);
    } else {
        plaintext->messageBytes = NULL;
    }
    return plaintext;
}

void ServerNoisePlaintextDestroy(void *payloadPointer) {
    if (!payloadPointer) {
        return;
    }
    ServerNoisePlaintext *plaintext = (ServerNoisePlaintext *)payloadPointer;
    if (plaintext->messageBytes) {
        BFMemoryRelease(plaintext->messageBytes);
        plaintext->messageBytes = NULL;
    }
    BFMemoryRelease(plaintext);
}

static void ServerEnqueueSend(ServerRuntimeContext *runtimeContext,
                              const uint8_t       *payloadBytes,
                              size_t               payloadLength,
                              const struct sockaddr_storage *peerAddress,
                              socklen_t            peerAddressLength) {
    if (!runtimeContext || !runtimeContext->networkOutputRunloop) {
        return;
    }
    ServerNetworkSendRequest *sendRequest = ServerNetworkSendRequestCreate(payloadBytes, payloadLength, peerAddress, peerAddressLength);
    if (!sendRequest) {
        BFWarn("boxd: unable to allocate send request");
        return;
    }
    BFRunloopEvent sendEvent = {
        .type    = ServerEventNetworkOutputSend,
        .payload = sendRequest,
        .destroy = ServerNetworkSendRequestDestroy,
    };
    if (BFRunloopPost(runtimeContext->networkOutputRunloop, &sendEvent) != BF_OK) {
        ServerNetworkSendRequestDestroy(sendRequest);
    }
}

static void ServerHandlePlainDatagram(ServerRuntimeContext *runtimeContext, ServerNetworkDatagram *datagram) {
    if (!runtimeContext || !datagram) {
        return;
    }

    if (!runtimeContext->handshakeCompleted) {
        uint16_t supportedVersions[1] = {1};
        uint64_t requestIdentifier    = 1;
        if (BFV1PackHelloToData(&runtimeContext->transmitBuffer, requestIdentifier, BFV1_STATUS_OK, supportedVersions, 1) == BF_OK) {
            ServerEnqueueSend(runtimeContext,
                              BFDataGetBytes(&runtimeContext->transmitBuffer),
                              BFDataGetLength(&runtimeContext->transmitBuffer),
                              &datagram->peerAddress,
                              datagram->peerAddressLength);
        }
        runtimeContext->handshakeCompleted = 1;
        return;
    }

    if (!datagram->datagramBytes || datagram->datagramLength == 0U) {
        return;
    }

    uint32_t       commandIdentifier    = 0;
    uint64_t       requestIdentifier    = 0;
    const uint8_t *payloadPointer       = NULL;
    uint32_t       payloadLength        = 0;
    int            unpacked             = BFV1Unpack(datagram->datagramBytes,
                                          (size_t)datagram->datagramLength,
                                          &commandIdentifier,
                                          &requestIdentifier,
                                          &payloadPointer,
                                          &payloadLength);
    if (unpacked < 0) {
        BFLog("boxd: trame v1 invalide");
        return;
    }

    switch (commandIdentifier) {
    case BFV1_HELLO: {
        uint8_t  statusCode         = 0xFFU;
        uint16_t versionBuffer[4]   = {0};
        uint8_t  versionCount       = 0;
        int      unpackedHello      = BFV1UnpackHello(payloadPointer,
                                                payloadLength,
                                                &statusCode,
                                                versionBuffer,
                                                (uint8_t)(sizeof(versionBuffer) / sizeof(versionBuffer[0])),
                                                &versionCount);
        if (unpackedHello == 0 && versionCount > 0U) {
            int hasCompatibleVersion = 0;
            for (uint8_t versionIndex = 0; versionIndex < versionCount; ++versionIndex) {
                if (versionBuffer[versionIndex] == 1U) {
                    hasCompatibleVersion = 1;
                    break;
                }
            }
            if (hasCompatibleVersion) {
                uint16_t supportedVersions[1] = {1};
                if (BFV1PackHelloToData(&runtimeContext->transmitBuffer,
                                        requestIdentifier + 1U,
                                        BFV1_STATUS_OK,
                                        supportedVersions,
                                        1) == BF_OK) {
                    ServerEnqueueSend(runtimeContext,
                                      BFDataGetBytes(&runtimeContext->transmitBuffer),
                                      BFDataGetLength(&runtimeContext->transmitBuffer),
                                      &datagram->peerAddress,
                                      datagram->peerAddressLength);
                }
            } else {
                if (BFV1PackStatusToData(&runtimeContext->transmitBuffer,
                                         BFV1_STATUS,
                                         requestIdentifier + 1U,
                                         BFV1_STATUS_BAD_REQUEST,
                                         "unsupported-version") == BF_OK) {
                    ServerEnqueueSend(runtimeContext,
                                      BFDataGetBytes(&runtimeContext->transmitBuffer),
                                      BFDataGetLength(&runtimeContext->transmitBuffer),
                                      &datagram->peerAddress,
                                      datagram->peerAddressLength);
                }
            }
        } else {
            if (BFV1PackStatusToData(&runtimeContext->transmitBuffer,
                                     BFV1_STATUS,
                                     requestIdentifier + 1U,
                                     BFV1_STATUS_BAD_REQUEST,
                                     "bad-hello") == BF_OK) {
                ServerEnqueueSend(runtimeContext,
                                  BFDataGetBytes(&runtimeContext->transmitBuffer),
                                  BFDataGetLength(&runtimeContext->transmitBuffer),
                                  &datagram->peerAddress,
                                  datagram->peerAddressLength);
            }
        }
        break;
    }
    case BFV1_STATUS: {
        BFLog("boxd: STATUS reçu (%u octets)", (unsigned)payloadLength);
        if (BFV1PackStatusToData(&runtimeContext->transmitBuffer,
                                 BFV1_STATUS,
                                 requestIdentifier + 1U,
                                 BFV1_STATUS_OK,
                                 "pong") == BF_OK) {
            ServerEnqueueSend(runtimeContext,
                              BFDataGetBytes(&runtimeContext->transmitBuffer),
                              BFDataGetLength(&runtimeContext->transmitBuffer),
                              &datagram->peerAddress,
                              datagram->peerAddressLength);
        }
        break;
    }
    case BFV1_PUT: {
        BFLog("boxd: PUT %u octets", (unsigned)payloadLength);
        const uint8_t *queuePathPointer   = NULL;
        uint16_t       queuePathLength    = 0;
        const uint8_t *contentTypePointer = NULL;
        uint16_t       contentTypeLength  = 0;
        const uint8_t *dataPointer        = NULL;
        uint32_t       dataLength         = 0;
        int unpackedPut = BFV1UnpackPut(payloadPointer,
                                        payloadLength,
                                        &queuePathPointer,
                                        &queuePathLength,
                                        &contentTypePointer,
                                        &contentTypeLength,
                                        &dataPointer,
                                        &dataLength);
        if (unpackedPut == 0) {
            char *queueKey = (char *)BFMemoryAllocate((size_t)queuePathLength + 1U);
            if (!queueKey) {
                break;
            }
            memcpy(queueKey, queuePathPointer, queuePathLength);
            queueKey[queuePathLength] = '\0';

            char *contentTypeString = (char *)BFMemoryAllocate((size_t)contentTypeLength + 1U);
            if (!contentTypeString) {
                BFMemoryRelease(queueKey);
                break;
            }
            memcpy(contentTypeString, contentTypePointer, contentTypeLength);
            contentTypeString[contentTypeLength] = '\0';

            StoredObject *storedObject = (StoredObject *)BFMemoryAllocate(sizeof(StoredObject));
            if (!storedObject) {
                BFMemoryRelease(queueKey);
                BFMemoryRelease(contentTypeString);
                break;
            }
            storedObject->contentType = contentTypeString;
            storedObject->dataLength  = dataLength;
            storedObject->data        = NULL;
            if (dataLength > 0) {
                storedObject->data = (uint8_t *)BFMemoryAllocate(dataLength);
                if (!storedObject->data) {
                    BFMemoryRelease(queueKey);
                    destroyStoredObjectCallback(storedObject);
                    break;
                }
                memcpy(storedObject->data, dataPointer, dataLength);
            }
            (void)BFSharedDictionarySet(runtimeContext->sharedStore, queueKey, storedObject);
            BFMemoryRelease(queueKey);

            if (BFV1PackStatusToData(&runtimeContext->transmitBuffer,
                                     BFV1_STATUS,
                                     requestIdentifier + 1U,
                                     BFV1_STATUS_OK,
                                     "stored") == BF_OK) {
                ServerEnqueueSend(runtimeContext,
                                  BFDataGetBytes(&runtimeContext->transmitBuffer),
                                  BFDataGetLength(&runtimeContext->transmitBuffer),
                                  &datagram->peerAddress,
                                  datagram->peerAddressLength);
            }
        } else {
            if (BFV1PackStatusToData(&runtimeContext->transmitBuffer,
                                     BFV1_STATUS,
                                     requestIdentifier + 1U,
                                     BFV1_STATUS_BAD_REQUEST,
                                     "bad-put") == BF_OK) {
                ServerEnqueueSend(runtimeContext,
                                  BFDataGetBytes(&runtimeContext->transmitBuffer),
                                  BFDataGetLength(&runtimeContext->transmitBuffer),
                                  &datagram->peerAddress,
                                  datagram->peerAddressLength);
            }
        }
        break;
    }
    case BFV1_GET: {
        const uint8_t *queuePathPointer = NULL;
        uint16_t       queuePathLength  = 0;
        int unpackedGet = BFV1UnpackGet(payloadPointer, payloadLength, &queuePathPointer, &queuePathLength);
        if (unpackedGet == 0) {
            char *queueKey = (char *)BFMemoryAllocate((size_t)queuePathLength + 1U);
            if (!queueKey) {
                break;
            }
            memcpy(queueKey, queuePathPointer, queuePathLength);
            queueKey[queuePathLength] = '\0';

            StoredObject *storedObject = (StoredObject *)BFSharedDictionaryGet(runtimeContext->sharedStore, queueKey);
            if (storedObject) {
                if (BFV1PackPutToData(&runtimeContext->transmitBuffer,
                                      requestIdentifier + 1U,
                                      queueKey,
                                      storedObject->contentType,
                                      storedObject->data,
                                      storedObject->dataLength) == BF_OK) {
                    ServerEnqueueSend(runtimeContext,
                                      BFDataGetBytes(&runtimeContext->transmitBuffer),
                                      BFDataGetLength(&runtimeContext->transmitBuffer),
                                      &datagram->peerAddress,
                                      datagram->peerAddressLength);
                }
            } else {
                if (BFV1PackStatusToData(&runtimeContext->transmitBuffer,
                                         BFV1_STATUS,
                                         requestIdentifier + 1U,
                                         BFV1_STATUS_BAD_REQUEST,
                                         "not-found") == BF_OK) {
                    ServerEnqueueSend(runtimeContext,
                                      BFDataGetBytes(&runtimeContext->transmitBuffer),
                                      BFDataGetLength(&runtimeContext->transmitBuffer),
                                      &datagram->peerAddress,
                                      datagram->peerAddressLength);
                }
            }
            BFMemoryRelease(queueKey);
        } else {
            if (BFV1PackStatusToData(&runtimeContext->transmitBuffer,
                                     BFV1_STATUS,
                                     requestIdentifier + 1U,
                                     BFV1_STATUS_BAD_REQUEST,
                                     "bad-get") == BF_OK) {
                ServerEnqueueSend(runtimeContext,
                                  BFDataGetBytes(&runtimeContext->transmitBuffer),
                                  BFDataGetLength(&runtimeContext->transmitBuffer),
                                  &datagram->peerAddress,
                                  datagram->peerAddressLength);
            }
        }
        break;
    }
    default: {
        BFLog("boxd: commande inconnue: %u", commandIdentifier);
        if (BFV1PackStatusToData(&runtimeContext->transmitBuffer,
                                 BFV1_STATUS,
                                 requestIdentifier + 1U,
                                 BFV1_STATUS_BAD_REQUEST,
                                 "unknown-command") == BF_OK) {
            ServerEnqueueSend(runtimeContext,
                              BFDataGetBytes(&runtimeContext->transmitBuffer),
                              BFDataGetLength(&runtimeContext->transmitBuffer),
                              &datagram->peerAddress,
                              datagram->peerAddressLength);
        }
        break;
    }
    }
}

static void ServerPrintUsage(const char *program) {
    fprintf(stderr,
            "Usage: %s [--port <udp>] [--log-level <lvl>] [--log-target <tgt>]\n"
            "          [--protocol <simple|v1>] [--cert <pem>] [--key <pem>]\n"
            "          [--pre-share-key-identity <id>] [--pre-share-key <ascii>] [--version] [--help]\n\n"
            "Options:\n"
            "  --port <udp>           UDP port to bind (default %u)\n"
            "  --log-level <lvl>      trace|debug|info|warn|error (default info)\n"
            "  --log-target <tgt>     override default platform target (Windows=eventlog, "
            "macOS=oslog, Unix=syslog, else=stderr); also accepts file:<path>\n"
            "  --protocol <mode>      simple|v1 (default simple)\n"
            "\n"
            "Notes:\n"
            "  - Refuses to run as root (Unix/macOS).\n"
            "  - Admin channel (Unix): ~/.box/run/boxd.socket (mode 0600); try 'box admin status'.\n"
            "  --version              Print version and exit\n"
            "  --help                 Show this help and exit\n",
            program, (unsigned)BFGlobalDefaultPort);
}

static void ServerParseArgs(int argc, char **argv, ServerNetworkOptions *outOptions) {
    memset(outOptions, 0, sizeof(*outOptions));
    for (int argumentIndex = 1; argumentIndex < argc; ++argumentIndex) {
        const char *arg = argv[argumentIndex];
        if (strcmp(arg, "--help") == 0 || strcmp(arg, "-h") == 0) {
            ServerPrintUsage(argv[0]);
            exit(0);
        } else if (strcmp(arg, "--version") == 0 || strcmp(arg, "-V") == 0) {
            fprintf(stdout, "boxd %s\n", BFVersionString());
            exit(0);
        } else if (strcmp(arg, "--log-level") == 0 && argumentIndex + 1 < argc) {
            const char *lvl = argv[++argumentIndex];
            if (strcmp(lvl, "trace") == 0) {
                BFLoggerSetLevel(BF_LOG_TRACE);
                outOptions->commandLineLogLevel = BF_LOG_TRACE;
                outOptions->hasLogLevel         = 1;
            } else if (strcmp(lvl, "debug") == 0) {
                BFLoggerSetLevel(BF_LOG_DEBUG);
                outOptions->commandLineLogLevel = BF_LOG_DEBUG;
                outOptions->hasLogLevel         = 1;
            } else if (strcmp(lvl, "info") == 0) {
                BFLoggerSetLevel(BF_LOG_INFO);
                outOptions->commandLineLogLevel = BF_LOG_INFO;
                outOptions->hasLogLevel         = 1;
            } else if (strcmp(lvl, "warn") == 0) {
                BFLoggerSetLevel(BF_LOG_WARN);
                outOptions->commandLineLogLevel = BF_LOG_WARN;
                outOptions->hasLogLevel         = 1;
            } else if (strcmp(lvl, "error") == 0) {
                BFLoggerSetLevel(BF_LOG_ERROR);
                outOptions->commandLineLogLevel = BF_LOG_ERROR;
                outOptions->hasLogLevel         = 1;
            }
        } else if (strcmp(arg, "--log-target") == 0 && argumentIndex + 1 < argc) {
            const char *target = argv[++argumentIndex];
            (void)BFLoggerSetTarget(target);
            strncpy(outOptions->commandLineLogTarget, target, sizeof(outOptions->commandLineLogTarget) - 1);
            outOptions->commandLineLogTarget[sizeof(outOptions->commandLineLogTarget) - 1] = '\0';
            outOptions->hasLogTarget                                                       = 1;
        } else if (strcmp(arg, "--port") == 0 && argumentIndex + 1 < argc) {
            const char *pv = argv[++argumentIndex];
            long        v  = strtol(pv, NULL, 10);
            if (v > 0 && v < 65536) {
                outOptions->port = (uint16_t)v;
            } else {
                BFError("Invalid --port: %s", pv);
                exit(2);
            }
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
        } else if (strcmp(arg, "--protocol") == 0 && argumentIndex + 1 < argc) {
            outOptions->protocol = argv[++argumentIndex];
        } else {
            BFError("Unknown option: %s", arg);
            ServerPrintUsage(argv[0]);
            exit(2);
        }
    }
}

static volatile int globalRunning = 1;
static void onInteruptSignal(int signalNumber) {
    (void)signalNumber;
    globalRunning = 0;
    BFLog("boxd: Interupt signal received. Exiting.");
    exit(-signalNumber);
}

void installSignalHandler(void) {
    signal(SIGINT, onInteruptSignal);
	BFLog("boxd: Signal handler installed.");
}

// Runloop handlers (placeholders for now)
static void ServerMainHandler(BFRunloop *runloop, BFRunloopEvent *event, void *context) {
    (void)runloop;
    if (!event) {
        return;
    }
    if (event->type == BFRunloopEventStop) {
        return;
    }

    ServerRuntimeContext *runtimeContext = (ServerRuntimeContext *)context;

#if defined(__unix__) || defined(__APPLE__)
    if (event->type == ServerEventAdminStatus) {
        ServerAdminRequest *adminRequest = (ServerAdminRequest *)event->payload;
        if (!adminRequest) {
            return;
        }
        const char *statusSubstring = strstr(adminRequest->requestBuffer, "status");
        if (statusSubstring != NULL) {
            char responseBuffer[256];
            int  responseSize = snprintf(responseBuffer,
                                         sizeof(responseBuffer),
                                         "{\"status\":\"ok\",\"version\":\"%s\"}\n",
                                         BFVersionString());
            if (responseSize < 0 || (size_t)responseSize >= sizeof(responseBuffer)) {
                responseSize = (int)strlen("{\"status\":\"ok\",\"version\":\"unknown\"}\n");
                strcpy(responseBuffer, "{\"status\":\"ok\",\"version\":\"unknown\"}\n");
            }
            if (ServerAdminWriteAll(adminRequest->clientSocketDescriptor,
                                    responseBuffer,
                                    (size_t)responseSize) != BF_OK) {
                BFWarn("boxd: admin status write failed");
            }
        } else {
            const char *messageText = "unknown-command\n";
            if (ServerAdminWriteAll(adminRequest->clientSocketDescriptor, messageText, strlen(messageText)) != BF_OK) {
                BFWarn("boxd: admin command write failed");
            }
        }
        if (adminRequest->clientSocketDescriptor >= 0) {
            close(adminRequest->clientSocketDescriptor);
            adminRequest->clientSocketDescriptor = -1;
        }
        return;
    }
#endif

    if (event->type == ServerEventNetworkDatagramInbound) {
        ServerNetworkDatagram *datagram = (ServerNetworkDatagram *)event->payload;
        if (runtimeContext && !runtimeContext->useNoiseTransport) {
            ServerHandlePlainDatagram(runtimeContext, datagram);
        }
        return;
    }

    if (event->type == ServerEventNoisePlaintext) {
        ServerNoisePlaintext *plaintext = (ServerNoisePlaintext *)event->payload;
        if (!runtimeContext || !runtimeContext->useNoiseTransport) {
            return;
        }
        if (plaintext && plaintext->messageBytes && plaintext->messageLength > 0U) {
            BFLog("boxd(noise): plaintext received (%zu bytes)", plaintext->messageLength);
        }
        const char *pongResponse = "pong";
        ServerEnqueueSend(runtimeContext,
                          (const uint8_t *)pongResponse,
                          strlen(pongResponse),
                          NULL,
                          0);
        return;
    }

    if (event->type == ServerEventTick) {
        BFRunloopEvent tick = {.type = ServerEventTick, .payload = NULL, .destroy = NULL};
        if (runtimeContext && runtimeContext->mainRunloop) {
            (void)BFRunloopPost(runtimeContext->mainRunloop, &tick);
        }
    }
}

static const char *getHomeDirectory(void) {
#if defined(__unix__) || defined(__APPLE__)
    const char *homeDirectory = getenv("HOME");
    if (!homeDirectory || !*homeDirectory) {
        struct passwd *pw = getpwuid(getuid());
        return pw->pw_dir;
    } else {
        return homeDirectory;
    }
    return NULL;
#else
    // Windows case
    return NULL;
#endif
}

static void createBoxDirectories(void) {
    // Create ~/.box and ~/.box/run with strict permissions (Unix-like)
#if defined(__unix__) || defined(__APPLE__)
    const char *homeDirectory = getHomeDirectory();
    char        pathBuffer[512];
    if (homeDirectory && *homeDirectory) {
        // ~/.box
        snprintf(pathBuffer, sizeof(pathBuffer), "%s/.box", homeDirectory);
        (void)mkdir(pathBuffer, 0700);
        chmod(pathBuffer, 0700);
        // ~/.box/run
        snprintf(pathBuffer, sizeof(pathBuffer), "%s/.box/run", homeDirectory);
        (void)mkdir(pathBuffer, 0700);
        chmod(pathBuffer, 0700);
    }
#endif
}

static void dontAllowRunningAsRoot(void) {
    // Non-root policy enforcement (Unix-like)
#if defined(__unix__) || defined(__APPLE__)
    if (geteuid() == 0) {
        BFError("boxd: must not run as root; refusing to start");
        exit(-77); // EX_NOPERM-like
    }
#endif
}

int main(int argc, char **argv) {
    ServerNetworkOptions options;
    ServerParseArgs(argc, argv, &options);
    BFLoggerInit("boxd");
    BFLoggerSetLevel(BF_LOG_INFO);
    installSignalHandler();

    dontAllowRunningAsRoot();

    createBoxDirectories();

    // Parse optional port from environment or default (CLI --port reserved for future)
    uint16_t    serverPort   = BFGlobalDefaultPort;
    const char *portOrigin   = "default";
    const char *portEnvValue = getenv("BOXD_PORT");
    if (options.port > 0) {
        serverPort = options.port;
        portOrigin = "cli-flag";
    } else if (portEnvValue && *portEnvValue) {
        long envPortValue = strtol(portEnvValue, NULL, 10);
        if (envPortValue > 0 && envPortValue < 65536) {
            serverPort = (uint16_t)envPortValue;
            portOrigin = "environment";
        }
    }

    // Apply config-based settings unless overridden by CLI
#if defined(__unix__) || defined(__APPLE__)
    BFServerConfig serverConfigurationLoaded;
    memset(&serverConfigurationLoaded, 0, sizeof(serverConfigurationLoaded));
    const char *homeDirectory = getHomeDirectory();
    if ((homeDirectory && *homeDirectory)) {
        char configPath[512];
        snprintf(configPath, sizeof(configPath), "%s/.box/boxd.toml", homeDirectory);
        if (BFConfigLoadServer(configPath, &serverConfigurationLoaded) == 0) {
            if (!options.hasLogLevel && serverConfigurationLoaded.hasLogLevel) {
                BFLoggerSetLevel(serverConfigurationLoaded.logLevel);
            }
            if (!options.hasLogTarget && serverConfigurationLoaded.hasLogTarget) {
                (void)BFLoggerSetTarget(serverConfigurationLoaded.logTarget);
            }
            if (serverConfigurationLoaded.hasNoisePattern) {
                BFLog("boxd: noise pattern set by config: %s", serverConfigurationLoaded.noisePattern);
            }
            // Adopt transport toggles and pre-shared key from config for smoke path
            if (!options.transport && serverConfigurationLoaded.hasTransportGeneral) {
                options.transport = serverConfigurationLoaded.transportGeneral;
            }
            if (!options.preShareKeyAscii && serverConfigurationLoaded.hasPreShareKeyAscii) {
                options.preShareKeyAscii = serverConfigurationLoaded.preShareKeyAscii;
            }
            if (!options.protocol && serverConfigurationLoaded.hasProtocol) {
                options.protocol = serverConfigurationLoaded.protocol;
            }
        }
    }
#endif

    // Log startup parameters (avoid printing secrets)
    char targetName[256] = {0};
    BFLoggerGetTarget(targetName, sizeof(targetName));
    const char *levelName        = BFLoggerLevelName(BFLoggerGetLevel());
    const char *protocolMode     = options.protocol ? options.protocol : "simple";
    int         enableProtocolV1 = 0;
    if (strcmp(protocolMode, "v1") == 0) {
        enableProtocolV1 = 1;
    } else if (strcmp(protocolMode, "simple") == 0) {
        enableProtocolV1 = 0;
    } else {
        BFWarn("boxd: protocole inconnu: %s (attendu simple|v1) — utilisation du mode simple", protocolMode);
        protocolMode     = "simple";
        enableProtocolV1 = 0;
    }
    BFProtocolSetV1Enabled(enableProtocolV1);
    BFLog("boxd: start port=%u portOrigin=%s logLevel=%s logTarget=%s config=%s cert=%s key=%s "
          "pskId=%s psk=%s transport=%s protocol=%s",
          (unsigned)serverPort, portOrigin, levelName, targetName,
          (
#if defined(__unix__) || defined(__APPLE__)
			(homeDirectory && *homeDirectory) ? "present" : "absent"
#else
            "absent"
#endif
		  ),
          options.certificateFile ? options.certificateFile : "(none)",
		  options.keyFile ? options.keyFile : "(none)",
		  options.preShareKeyIdentity ? options.preShareKeyIdentity : "(none)",
		  options.preShareKeyAscii ? "[set]" : "(unset)",
		  options.transport ? options.transport : "(default)", protocolMode);

    // Create in-memory store for demo
    BFSharedDictionary *store = BFSharedDictionaryCreate(destroyStoredObjectCallback);
    if (!store) {
        BFFatal("cannot allocate store");
    }

    int udpSocket = BFUdpServer(serverPort);
    if (udpSocket < 0) {
        BFFatal("BFUdpServer");
    }

    ServerRuntimeContext runtimeContext;
    memset(&runtimeContext, 0, sizeof(runtimeContext));
    runtimeContext.udpSocketDescriptor  = udpSocket;
    runtimeContext.sharedStore          = store;
    runtimeContext.runningFlagPointer   = &globalRunning;
    runtimeContext.useNoiseTransport    = 0;
    runtimeContext.handshakeCompleted   = 0;
    runtimeContext.transmitBuffer       = BFDataCreate(0U);

    // Admin channel (Unix domain socket, non-bloquant, minimal skeleton)
#if defined(__unix__) || defined(__APPLE__)
    int                      adminListenSocket = -1;
    BFRunloop               *adminRunloop      = NULL;
    ServerAdminThreadContext adminThreadContext;
	pthread_t                adminThread = NULL;
    int                      adminThreadStarted = 0;
    memset(&adminThreadContext, 0, sizeof(adminThreadContext));
    if (homeDirectory && *homeDirectory) {
        char adminSocketPath[512];
        snprintf(adminSocketPath, sizeof(adminSocketPath), "%s/.box/run/boxd.socket", homeDirectory);
        adminListenSocket = (int)socket(AF_UNIX, SOCK_STREAM, 0);
        if (adminListenSocket >= 0) {
            struct sockaddr_un adminAddress;
            memset(&adminAddress, 0, sizeof(adminAddress));
            adminAddress.sun_family = AF_UNIX;
            strncpy(adminAddress.sun_path, adminSocketPath, sizeof(adminAddress.sun_path) - 1);
            // Remove any stale socket file, then bind
            unlink(adminSocketPath);
            if (bind(adminListenSocket, (struct sockaddr *)&adminAddress, sizeof(adminAddress)) == 0) {
                (void)chmod(adminSocketPath, 0600);
                (void)listen(adminListenSocket, 4);
                BFLog("boxd: admin channel ready at %s", adminSocketPath);
                adminThreadContext.listenSocketDescriptor = adminListenSocket;
                adminThreadContext.runningFlagPointer     = &globalRunning;
                adminRunloop                              = BFRunloopCreate();
                if (!adminRunloop) {
                    BFWarn("boxd: unable to create admin runloop");
                    close(adminListenSocket);
                    adminListenSocket = -1;
                    unlink(adminSocketPath);
                    adminThreadContext.listenSocketDescriptor = -1;
                } else if (BFRunloopSetHandler(adminRunloop, ServerMainHandler, &runtimeContext) != BF_OK) {
                    BFWarn("boxd: unable to configure admin runloop");
                    BFRunloopFree(adminRunloop);
                    adminRunloop = NULL;
                    close(adminListenSocket);
                    adminListenSocket = -1;
                    unlink(adminSocketPath);
                    adminThreadContext.listenSocketDescriptor = -1;
                } else if (BFRunloopStart(adminRunloop) != BF_OK) {
                    BFWarn("boxd: unable to start admin runloop");
                    BFRunloopFree(adminRunloop);
                    adminRunloop = NULL;
                    close(adminListenSocket);
                    adminListenSocket = -1;
                    unlink(adminSocketPath);
                    adminThreadContext.listenSocketDescriptor = -1;
                } else {
                    adminThreadContext.runloop = adminRunloop;
                    if (pthread_create(&adminThread, NULL, ServerAdminListenerThread, &adminThreadContext) == 0) {
                        adminThreadStarted = 1;
                    } else {
                        BFWarn("boxd: unable to start admin listener thread");
                        BFRunloopPostStop(adminRunloop);
                        BFRunloopJoin(adminRunloop);
                        BFRunloopFree(adminRunloop);
                        adminRunloop               = NULL;
                        adminThreadContext.runloop = NULL;
                        close(adminListenSocket);
                        adminListenSocket = -1;
                        unlink(adminSocketPath);
                        adminThreadContext.listenSocketDescriptor = -1;
                    }
                }
            } else {
                BFError("boxd: failed to bind admin channel");
                close(adminListenSocket);
                adminListenSocket                         = -1;
                adminThreadContext.listenSocketDescriptor = -1;
            }
        }
    }
#endif // __unix__ || __APPLE__

    // Noise transport (optional smoke mode): enter encrypted echo loop if requested
    int useNoiseSmoke = (options.transport && strcmp(options.transport, "noise") == 0)
#if defined(__unix__) || defined(__APPLE__)
                        || (serverConfigurationLoaded.hasTransportStatus && strcmp(serverConfigurationLoaded.transportStatus, "noise") == 0)
#endif
        ;
    runtimeContext.useNoiseTransport = useNoiseSmoke ? 1 : 0;
    if (runtimeContext.useNoiseTransport) {
        memset(&runtimeContext.noiseSecurity, 0, sizeof(runtimeContext.noiseSecurity));
        runtimeContext.hasNoiseSecurity = 1;
        if (options.preShareKeyAscii) {
            runtimeContext.noiseSecurity.preShareKey       = (const unsigned char *)options.preShareKeyAscii;
            runtimeContext.noiseSecurity.preShareKeyLength = (size_t)strlen(options.preShareKeyAscii);
        }
#if defined(__unix__) || defined(__APPLE__)
        if (serverConfigurationLoaded.hasNoisePattern) {
            runtimeContext.noiseSecurity.hasNoiseHandshakePattern = 1;
            if (strcmp(serverConfigurationLoaded.noisePattern, "nk") == 0) {
                runtimeContext.noiseSecurity.noiseHandshakePattern = BFNoiseHandshakePatternNK;
            } else if (strcmp(serverConfigurationLoaded.noisePattern, "ik") == 0) {
                runtimeContext.noiseSecurity.noiseHandshakePattern = BFNoiseHandshakePatternIK;
            } else {
                runtimeContext.noiseSecurity.hasNoiseHandshakePattern = 0;
            }
        }
#endif
    }

    runtimeContext.mainRunloop        = BFRunloopCreate();
    runtimeContext.networkInputRunloop = BFRunloopCreate();
    runtimeContext.networkOutputRunloop = BFRunloopCreate();
    if (!runtimeContext.mainRunloop || !runtimeContext.networkInputRunloop || !runtimeContext.networkOutputRunloop) {
        BFFatal("boxd: unable to allocate runloops");
    }
    if (BFRunloopSetHandler(runtimeContext.mainRunloop, ServerMainHandler, &runtimeContext) != BF_OK) {
        BFFatal("boxd: unable to configure main runloop");
    }
    if (BFRunloopSetHandler(runtimeContext.networkInputRunloop, ServerNetworkInputHandler, &runtimeContext) != BF_OK) {
        BFFatal("boxd: unable to configure network input runloop");
    }
    if (BFRunloopSetHandler(runtimeContext.networkOutputRunloop, ServerNetworkOutputHandler, &runtimeContext) != BF_OK) {
        BFFatal("boxd: unable to configure network output runloop");
    }

    BFRunloopEvent socketEvent = {
        .type    = ServerEventNetworkSocketReadable,
        .payload = NULL,
        .destroy = NULL,
    };
    if (BFRunloopAddFileDescriptor(runtimeContext.networkInputRunloop,
                                   runtimeContext.udpSocketDescriptor,
                                   BFRunloopFdModeRead,
                                   &socketEvent) == BF_OK) {
        runtimeContext.hasReactor = 1;
    } else {
        runtimeContext.hasReactor = 0;
        BFWarn("boxd: falling back to threaded receive loop (no reactor backend)");
    }
    if (BFRunloopStart(runtimeContext.networkInputRunloop) != BF_OK) {
        BFFatal("boxd: unable to start network input runloop");
    }
    if (BFRunloopStart(runtimeContext.networkOutputRunloop) != BF_OK) {
        BFFatal("boxd: unable to start network output runloop");
    }
    if (!runtimeContext.hasReactor) {
        BFRunloopEvent startEvent = {
            .type    = ServerEventNetworkInputStart,
            .payload = NULL,
            .destroy = NULL,
        };
        (void)BFRunloopPost(runtimeContext.networkInputRunloop, &startEvent);
    }

    BFRunloopRun(runtimeContext.mainRunloop);

cleanup:
    close(udpSocket);
    BFDataReset(&runtimeContext.transmitBuffer);
    if (runtimeContext.noiseConnection) {
        BFNetworkClose(runtimeContext.noiseConnection);
        runtimeContext.noiseConnection = NULL;
    }
    if (runtimeContext.hasReactor && runtimeContext.networkInputRunloop) {
        (void)BFRunloopRemoveFileDescriptor(runtimeContext.networkInputRunloop, runtimeContext.udpSocketDescriptor);
    }
    if (runtimeContext.networkInputRunloop) {
        BFRunloopPostStop(runtimeContext.networkInputRunloop);
        BFRunloopJoin(runtimeContext.networkInputRunloop);
        BFRunloopFree(runtimeContext.networkInputRunloop);
        runtimeContext.networkInputRunloop = NULL;
    }
    if (runtimeContext.networkOutputRunloop) {
        BFRunloopPostStop(runtimeContext.networkOutputRunloop);
        BFRunloopJoin(runtimeContext.networkOutputRunloop);
        BFRunloopFree(runtimeContext.networkOutputRunloop);
        runtimeContext.networkOutputRunloop = NULL;
    }
    if (runtimeContext.mainRunloop) {
        BFRunloopFree(runtimeContext.mainRunloop);
        runtimeContext.mainRunloop = NULL;
    }
#if defined(__unix__) || defined(__APPLE__)
    globalRunning = 0;
    if (adminListenSocket >= 0) {
        close(adminListenSocket);
        adminListenSocket                         = -1;
        adminThreadContext.listenSocketDescriptor = -1;
    }
    if (adminThreadStarted) {
        (void)pthread_join(adminThread, NULL);
    }
    if (adminRunloop) {
        BFRunloopPostStop(adminRunloop);
        BFRunloopJoin(adminRunloop);
        BFRunloopFree(adminRunloop);
        adminRunloop = NULL;
    }
#endif
    return 0;
}
