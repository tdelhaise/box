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

#include <arpa/inet.h>
#include <fcntl.h>
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

typedef struct ServerDtlsOptions {
    const char *certificateFile;
    const char *keyFile;
    const char *preShareKeyIdentity;
    const char *preShareKeyAscii;
    const char *transport;
    uint16_t    port; // optional CLI override
    int         hasLogLevel;
    BFLogLevel  commandLineLogLevel;
    int         hasLogTarget;
    char        commandLineLogTarget[128];
} ServerDtlsOptions;

// Simple in-memory object for demo GET/PUT
typedef struct StoredObject {
    char    *contentType;
    uint8_t *data;
    uint32_t dataLength;
} StoredObject;

static void destroyStoredObject(void *pointer) {
    if (!pointer)
        return;
    StoredObject *object = (StoredObject *)pointer;
    if (object->contentType)
        BFMemoryRelease(object->contentType);
    if (object->data)
        BFMemoryRelease(object->data);
    BFMemoryRelease(object);
}

static void ServerPrintUsage(const char *program) {
    fprintf(stderr,
            "Usage: %s [--port <udp>] [--log-level <lvl>] [--log-target <tgt>]\n"
            "          [--cert <pem>] [--key <pem>] [--pre-share-key-identity <id>]\n"
            "          [--pre-share-key <ascii>] [--version] [--help]\n\n"
            "Options:\n"
            "  --port <udp>           UDP port to bind (default %u)\n"
            "  --log-level <lvl>      trace|debug|info|warn|error (default info)\n"
            "  --log-target <tgt>     override default platform target (Windows=eventlog, "
            "macOS=oslog, Unix=syslog, else=stderr); also accepts file:<path>\n"
            "\n"
            "Notes:\n"
            "  - Refuses to run as root (Unix/macOS).\n"
            "  - Admin channel (Unix): ~/.box/run/boxd.socket (mode 0600); try 'box admin status'.\n"
            "  --version              Print version and exit\n"
            "  --help                 Show this help and exit\n",
            program, (unsigned)BFGlobalDefaultPort);
}

static void ServerParseArgs(int argc, char **argv, ServerDtlsOptions *outOptions) {
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
        } else {
            BFError("Unknown option: %s", arg);
            ServerPrintUsage(argv[0]);
            exit(2);
        }
    }
}

// --- Simple BFRunloop-based threading skeleton (net-in, net-out, main) ---
static BFRunloop *globalRunloopMain   = NULL;
static BFRunloop *globalRunloopNetIn  = NULL;
static BFRunloop *globalRunloopNetOut = NULL;

static volatile int globalRunning = 1;
static void         onInteruptSignal(int signalNumber) {
    (void)signalNumber;
    globalRunning = 0;
    BFLog("boxd: Interupt signal received. Exiting.");
    exit(-signalNumber);
}

void installSignalHandler(void) {
    signal(SIGINT, onInteruptSignal);
}

// Runloop handlers (placeholders for now)
typedef enum ServerEventType { ServerEventTick = 1000 } ServerEventType;

static void ServerMainHandler(BFRunloop *runloop, BFRunloopEvent *event, void *context) {
    (void)context;
    if (event->type == BFRunloopEventStop) {
        return;
    }
    if (event->type == ServerEventTick) {
        // Re-post a low-frequency tick as a heartbeat example
        BFRunloopEvent tick = {.type = ServerEventTick, .payload = NULL, .destroy = NULL};
        (void)BFRunloopPost(runloop, &tick);
    }
}

static void ServerNetInHandler(BFRunloop *runloop, BFRunloopEvent *event, void *context) {
    (void)runloop;
    (void)context;
    if (event->type == BFRunloopEventStop)
        return;
}

static void ServerNetOutHandler(BFRunloop *runloop, BFRunloopEvent *event, void *context) {
    (void)runloop;
    (void)context;
    if (event->type == BFRunloopEventStop)
        return;
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
    ServerDtlsOptions options;
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
        }
    }
#endif

    // Log startup parameters (avoid printing secrets)
    char targetName[256] = {0};
    BFLoggerGetTarget(targetName, sizeof(targetName));
    const char *levelName = BFLoggerLevelName(BFLoggerGetLevel());
    BFLog("boxd: start port=%u portOrigin=%s logLevel=%s logTarget=%s config=%s cert=%s key=%s "
          "pskId=%s psk=%s transport=%s",
          (unsigned)serverPort, portOrigin, levelName, targetName,
          (
#if defined(__unix__) || defined(__APPLE__)
              (homeDirectory && *homeDirectory) ? "present" : "absent"
#else
              "absent"
#endif
              ),
          options.certificateFile ? options.certificateFile : "(none)", options.keyFile ? options.keyFile : "(none)", options.preShareKeyIdentity ? options.preShareKeyIdentity : "(none)", options.preShareKeyAscii ? "[set]" : "(unset)", options.transport ? options.transport : "(default)");

    // Create in-memory store for demo
    BFSharedDictionary *store = BFSharedDictionaryCreate(destroyStoredObject);
    if (!store) {
        BFFatal("cannot allocate store");
    }

    int udpSocket = BFUdpServer(serverPort);
    if (udpSocket < 0) {
        BFFatal("BFUdpServer");
    }

    // Admin channel (Unix domain socket, non-bloquant, minimal skeleton)
    int adminListenSocket = -1;
#if defined(__unix__) || defined(__APPLE__)
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
                // Non-blocking accept
                int flags = fcntl(adminListenSocket, F_GETFL, 0);
                if (flags >= 0)
                    (void)fcntl(adminListenSocket, F_SETFL, flags | O_NONBLOCK);
                BFLog("boxd: admin channel ready at %s", adminSocketPath);
            } else {
                BFError("boxd: failed to bind admin channel");
                close(adminListenSocket);
                adminListenSocket = -1;
            }
        }
    }
#endif

    // 1) Attente d'un datagram clair pour connaître l'adresse du client
    struct sockaddr_storage peer       = {0};
    socklen_t               peerLength = sizeof(peer);
    uint8_t                 receiveBuffer[BF_MACRO_MAX_DATAGRAM_SIZE];

    memset(receiveBuffer, 0, sizeof(receiveBuffer));

    ssize_t received = BFUdpReceive(udpSocket, receiveBuffer, sizeof(receiveBuffer), (struct sockaddr *)&peer, &peerLength);
    if (received < 0) {
        BFFatal("recvfrom (hello)");
    }

    BFLog("boxd: datagram initial %zd octets reçu", received);

    // 2) Noise transport (optional smoke mode): enter encrypted echo loop if requested
    // Allow per-operation override for status smoke via config
    int useNoiseSmoke = (options.transport && strcmp(options.transport, "noise") == 0)
#if defined(__unix__) || defined(__APPLE__)
                        || (serverConfigurationLoaded.hasTransportStatus && strcmp(serverConfigurationLoaded.transportStatus, "noise") == 0)
#endif
        ;
    if (useNoiseSmoke) {
        BFNetworkSecurity security = {0};
        if (options.preShareKeyAscii) {
            security.preShareKey       = (const unsigned char *)options.preShareKeyAscii;
            security.preShareKeyLength = (size_t)strlen(options.preShareKeyAscii);
        }
        // Map noise pattern from config when present (scaffold)
#if defined(__unix__) || defined(__APPLE__)
        if (serverConfigurationLoaded.hasNoisePattern) {
            security.hasNoiseHandshakePattern = 1;
            if (strcmp(serverConfigurationLoaded.noisePattern, "nk") == 0) {
                security.noiseHandshakePattern = BFNoiseHandshakePatternNK;
            } else if (strcmp(serverConfigurationLoaded.noisePattern, "ik") == 0) {
                security.noiseHandshakePattern = BFNoiseHandshakePatternIK;
            } else {
                security.hasNoiseHandshakePattern = 0;
            }
        }
#endif
        BFNetworkConnection *networkConnection = BFNetworkAcceptDatagram(BFNetworkTransportNOISE, udpSocket, &peer, peerLength, &security);
        if (!networkConnection) {
            BFFatal("Noise accept failed");
        }
        for (;;) {
            char plaintext[256];
            int  receivedBytes = BFNetworkReceive(networkConnection, plaintext, (int)sizeof(plaintext));
            if (receivedBytes <= 0) {
                BFWarn("boxd(noise): recv error");
                break;
            }
            BFLog("boxd(noise): received %d bytes", receivedBytes);
            const char *pong = "pong";
            if (BFNetworkSend(networkConnection, pong, (int)strlen(pong)) <= 0) {
                BFWarn("boxd(noise): send error");
                break;
            }
        }
        BFNetworkClose(networkConnection);
        close(udpSocket);
        return 0;
    }

    // 3) Pas de DTLS: échanges v1 en UDP clair

    // Envoyer un HELLO applicatif (v1) en UDP clair avec statut OK et versions supportées
    uint8_t  transmitBuffer[BF_MACRO_MAX_DATAGRAM_SIZE];
    uint64_t requestId            = 1;
    uint16_t supportedVersions[1] = {1};
    int      packed               = BFV1PackHello(transmitBuffer, sizeof(transmitBuffer), requestId, BFV1_STATUS_OK, supportedVersions, 1);
    if (packed > 0) {
        (void)BFUdpSend(udpSocket, transmitBuffer, (size_t)packed, (struct sockaddr *)&peer, peerLength);
    }

    // 4) Boucle simple: attendre STATUS (ping) et répondre STATUS (pong)
    int consecutiveErrors = 0;
    while (globalRunning) {
        // Handle one admin connection if pending (non-blocking)
#if defined(__unix__) || defined(__APPLE__)
        if (adminListenSocket >= 0) {
            int adminClient = accept(adminListenSocket, NULL, NULL);
            if (adminClient >= 0) {
                char    requestBuffer[128] = {0};
                ssize_t requestSize        = read(adminClient, requestBuffer, sizeof(requestBuffer));
                if (requestSize > 0) {
                    // Trim and check for "status"
                    if (strstr(requestBuffer, "status") != NULL) {
                        char response[256];
                        snprintf(response, sizeof(response), "{\"status\":\"ok\",\"version\":\"%s\"}\n", BFVersionString());
                        (void)write(adminClient, response, strlen(response));
                    } else {
                        const char *messageText = "unknown-command\n";
                        (void)write(adminClient, messageText, strlen(messageText));
                    }
                }
                close(adminClient);
            }
        }
#endif
        struct sockaddr_storage from       = {0};
        socklen_t               fromLength = sizeof(from);
        int                     readCount  = (int)BFUdpReceive(udpSocket, receiveBuffer, sizeof(receiveBuffer), (struct sockaddr *)&from, &fromLength);
        if (readCount <= 0) {
            consecutiveErrors++;
            BFWarn("boxd: lecture UDP en erreur (compteur=%d)", consecutiveErrors);
            if (consecutiveErrors > 5) {
                BFError("boxd: trop d'erreurs consécutives en lecture, arrêt de la boucle");
                break;
            }
            continue;
        }
        consecutiveErrors            = 0;
        uint32_t       command       = 0;
        uint64_t       receivedReqId = 0;
        const uint8_t *payload       = NULL;
        uint32_t       payloadLength = 0;
        int            unpacked      = BFV1Unpack(receiveBuffer, (size_t)readCount, &command, &receivedReqId, &payload, &payloadLength);
        if (unpacked < 0) {
            BFLog("boxd: trame v1 invalide");
            continue;
        }
        switch (command) {
        case BFV1_HELLO: {
            uint8_t  statusCode   = 0xFF;
            uint16_t versions[4]  = {0};
            uint8_t  versionCount = 0;
            int      ok           = BFV1UnpackHello(payload, payloadLength, &statusCode, versions, (uint8_t)(sizeof(versions) / sizeof(versions[0])), &versionCount);
            if (ok == 0 && versionCount > 0) {
                int hasCompatible = 0;
                for (uint8_t vi = 0; vi < versionCount; ++vi) {
                    if (versions[vi] == 1) {
                        hasCompatible = 1;
                        break;
                    }
                }
                if (hasCompatible) {
                    uint16_t supported[1] = {1};
                    int      responseSize = BFV1PackHello(transmitBuffer, sizeof(transmitBuffer), receivedReqId + 1, BFV1_STATUS_OK, supported, 1);
                    if (responseSize > 0) {
                        (void)BFUdpSend(udpSocket, transmitBuffer, (size_t)responseSize, (struct sockaddr *)&from, fromLength);
                    }
                } else {
                    int responseSize = BFV1PackStatus(transmitBuffer, sizeof(transmitBuffer), BFV1_STATUS, receivedReqId + 1, BFV1_STATUS_BAD_REQUEST, "unsupported-version");
                    if (responseSize > 0) {
                        (void)BFUdpSend(udpSocket, transmitBuffer, (size_t)responseSize, (struct sockaddr *)&from, fromLength);
                    }
                }
            } else {
                int responseSize = BFV1PackStatus(transmitBuffer, sizeof(transmitBuffer), BFV1_STATUS, receivedReqId + 1, BFV1_STATUS_BAD_REQUEST, "bad-hello");
                if (responseSize > 0) {
                    (void)BFUdpSend(udpSocket, transmitBuffer, (size_t)responseSize, (struct sockaddr *)&from, fromLength);
                }
            }
            break;
        }
        case BFV1_STATUS: {
            BFLog("boxd: STATUS reçu (%u octets)", (unsigned)payloadLength);
            int responseSize = BFV1PackStatus(transmitBuffer, sizeof(transmitBuffer), BFV1_STATUS, receivedReqId + 1, BFV1_STATUS_OK, "pong");
            if (responseSize > 0)
                (void)BFUdpSend(udpSocket, transmitBuffer, (size_t)responseSize, (struct sockaddr *)&from, fromLength);
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
            int            ok                 = BFV1UnpackPut(payload, payloadLength, &queuePathPointer, &queuePathLength, &contentTypePointer, &contentTypeLength, &dataPointer, &dataLength);
            if (ok == 0) {
                BFLog("boxd: PUT path=%.*s contentType=%.*s size=%u", (int)queuePathLength, (const char *)queuePathPointer, (int)contentTypeLength, (const char *)contentTypePointer, (unsigned)dataLength);
                // build in-memory object
                char *queueKey = (char *)BFMemoryAllocate((size_t)queuePathLength + 1U);
                if (!queueKey)
                    break;
                memcpy(queueKey, queuePathPointer, queuePathLength);
                queueKey[queuePathLength] = '\0';
                char *contentTypeStr      = (char *)BFMemoryAllocate((size_t)contentTypeLength + 1U);
                if (!contentTypeStr) {
                    BFMemoryRelease(queueKey);
                    break;
                }
                memcpy(contentTypeStr, contentTypePointer, contentTypeLength);
                contentTypeStr[contentTypeLength] = '\0';
                StoredObject *object              = (StoredObject *)BFMemoryAllocate(sizeof(StoredObject));
                if (!object) {
                    BFMemoryRelease(queueKey);
                    BFMemoryRelease(contentTypeStr);
                    break;
                }
                object->contentType = contentTypeStr;
                object->dataLength  = dataLength;
                object->data        = NULL;
                if (dataLength > 0) {
                    object->data = (uint8_t *)BFMemoryAllocate(dataLength);
                    if (!object->data) {
                        BFMemoryRelease(queueKey);
                        destroyStoredObject(object);
                        break;
                    }
                    memcpy(object->data, dataPointer, dataLength);
                }
                (void)BFSharedDictionarySet(store, queueKey, object);
                BFMemoryRelease(queueKey);
                int responseSize = BFV1PackStatus(transmitBuffer, sizeof(transmitBuffer), BFV1_STATUS, receivedReqId + 1, BFV1_STATUS_OK, "stored");
                if (responseSize > 0)
                    (void)BFUdpSend(udpSocket, transmitBuffer, (size_t)responseSize, (struct sockaddr *)&from, fromLength);
            } else {
                int responseSize = BFV1PackStatus(transmitBuffer, sizeof(transmitBuffer), BFV1_STATUS, receivedReqId + 1, BFV1_STATUS_BAD_REQUEST, "bad-put");
                if (responseSize > 0)
                    (void)BFUdpSend(udpSocket, transmitBuffer, (size_t)responseSize, (struct sockaddr *)&from, fromLength);
            }
            break;
        }
        case BFV1_GET: {
            const uint8_t *queuePathPointer = NULL;
            uint16_t       queuePathLength  = 0;
            int            ok               = BFV1UnpackGet(payload, payloadLength, &queuePathPointer, &queuePathLength);
            if (ok == 0) {
                char *queueKey = (char *)BFMemoryAllocate((size_t)queuePathLength + 1U);
                if (!queueKey)
                    break;
                memcpy(queueKey, queuePathPointer, queuePathLength);
                queueKey[queuePathLength] = '\0';
                StoredObject *object      = (StoredObject *)BFSharedDictionaryGet(store, queueKey);
                if (object) {
                    int responseSize = BFV1PackPut(transmitBuffer, sizeof(transmitBuffer), receivedReqId + 1, queueKey, object->contentType, object->data, object->dataLength);
                    if (responseSize > 0)
                        (void)BFUdpSend(udpSocket, transmitBuffer, (size_t)responseSize, (struct sockaddr *)&from, fromLength);
                } else {
                    int responseSize = BFV1PackStatus(transmitBuffer, sizeof(transmitBuffer), BFV1_STATUS, receivedReqId + 1, BFV1_STATUS_BAD_REQUEST, "not-found");
                    if (responseSize > 0)
                        (void)BFUdpSend(udpSocket, transmitBuffer, (size_t)responseSize, (struct sockaddr *)&from, fromLength);
                }
                BFMemoryRelease(queueKey);
            } else {
                int responseSize = BFV1PackStatus(transmitBuffer, sizeof(transmitBuffer), BFV1_STATUS, receivedReqId + 1, BFV1_STATUS_BAD_REQUEST, "bad-get");
                if (responseSize > 0)
                    (void)BFUdpSend(udpSocket, transmitBuffer, (size_t)responseSize, (struct sockaddr *)&from, fromLength);
            }
            break;
        }
        default: {
            BFLog("boxd: commande inconnue: %u", command);
            int responseSize = BFV1PackStatus(transmitBuffer, sizeof(transmitBuffer), BFV1_STATUS, receivedReqId + 1, BFV1_STATUS_BAD_REQUEST, "unknown-command");
            if (responseSize > 0) {
                (void)BFUdpSend(udpSocket, transmitBuffer, (size_t)responseSize, (struct sockaddr *)&from, fromLength);
            }
            break;
        }
        }
    }

    close(udpSocket);
#if defined(__unix__) || defined(__APPLE__)
    if (adminListenSocket >= 0)
        close(adminListenSocket);
#endif
    return 0;
}
