#include "box/BFBoxProtocolV1.h"
#include "box/BFCommon.h"
#include "box/BFRunloop.h"
#include "box/BFUdp.h"
#include "box/BFUdpServer.h"

#include <arpa/inet.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

typedef struct ServerDtlsOptions {
    const char *certificateFile;
    const char *keyFile;
    const char *preShareKeyIdentity;
    const char *preShareKeyAscii;
    const char *transport;
} ServerDtlsOptions;

static void ServerPrintUsage(const char *program) {
    fprintf(stderr,
            "Usage: %s [--cert <pem>] [--key <pem>] [--pre-share-key-identity <id>]\n"
            "          [--pre-share-key <ascii>]\n",
            program);
}

static void ServerParseArgs(int argc, char **argv, ServerDtlsOptions *outOptions) {
    memset(outOptions, 0, sizeof(*outOptions));
    for (int argumentIndex = 1; argumentIndex < argc; ++argumentIndex) {
        const char *arg = argv[argumentIndex];
        if (strcmp(arg, "--help") == 0 || strcmp(arg, "-h") == 0) {
            ServerPrintUsage(argv[0]);
            exit(0);
        } else if (strcmp(arg, "--cert") == 0 && i + 1 < argc) {
            outOptions->certificateFile = argv[++argumentIndex];
        } else if (strcmp(arg, "--key") == 0 && i + 1 < argc) {
            outOptions->keyFile = argv[++argumentIndex];
        } else if (strcmp(arg, "--pre-share-key-identity") == 0 && i + 1 < argc) {
            outOptions->preShareKeyIdentity = argv[++argumentIndex];
        } else if (strcmp(arg, "--pre-share-key") == 0 && i + 1 < argc) {
            outOptions->preShareKeyAscii = argv[++argumentIndex];
        } else if (strcmp(arg, "--transport") == 0 && i + 1 < argc) {
            outOptions->transport = argv[++argumentIndex];
        } else {
            BFError("Unknown option: %s", arg);
            ServerPrintUsage(argv[0]);
            exit(2);
        }
    }
}

// --- Simple BFRunloop-based threading skeleton (net-in, net-out, main) ---
static BFRunloop *staticGlobalRunloopMain   = NULL;
static BFRunloop *staticGlobalRunloopNetIn  = NULL;
static BFRunloop *staticGlobalRunloopNetOut = NULL;

static volatile int g_running = 1;
static void         on_sigint(int sig) {
    (void)sig;
    g_running = 0;
    BFLog("boxd: Interupt signal received. Exiting.");
    exit(-sig);
}

void install_signal_handler(void) {
    signal(SIGINT, on_sigint);
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

int main(int argc, char **argv) {
    ServerDtlsOptions options;
    ServerParseArgs(argc, argv, &options);
    install_signal_handler();

    int udpSocket = BFUdpServer(BFDefaultPort);
    if (udpSocket < 0) {
        BFFatal("BFUdpServer");
    }

    // 1) Attente d'un datagram clair pour connaître l'adresse du client
    struct sockaddr_storage peer       = {0};
    socklen_t               peerLength = sizeof(peer);
    uint8_t                 receiveBuffer[BFMaxDatagram];

    memset(receiveBuffer, 0, sizeof(receiveBuffer));

    ssize_t received = BFUdpRecieve(udpSocket, receiveBuffer, sizeof(receiveBuffer),
                                    (struct sockaddr *)&peer, &peerLength);
    if (received < 0) {
        BFFatal("recvfrom (hello)");
    }

    BFLog("boxd: datagram initial %zd octets reçu", received);

    // 2) Pas de DTLS: échanges v1 en UDP clair

    // 3) Envoyer un HELLO applicatif (v1) en UDP clair avec statut OK
    uint8_t  transmitBuffer[BFMaxDatagram];
    uint64_t requestId = 1;
    int      packed = BFV1PackStatus(transmitBuffer, sizeof(transmitBuffer), BFV1_HELLO, requestId,
                                     BFV1_STATUS_OK, "server-ready");
    if (packed > 0) {
        (void)BFUdpSend(udpSocket, transmitBuffer, (size_t)packed, (struct sockaddr *)&peer,
                        peerLength);
    }

    // 4) Boucle simple: attendre STATUS (ping) et répondre STATUS (pong)
    int consecutiveErrors = 0;
    while (g_running) {
        struct sockaddr_storage from       = {0};
        socklen_t               fromLength = sizeof(from);
        int readCount = (int)BFUdpRecieve(udpSocket, receiveBuffer, sizeof(receiveBuffer),
                                          (struct sockaddr *)&from, &fromLength);
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
        int unpacked = BFV1Unpack(receiveBuffer, (size_t)readCount, &command, &receivedReqId,
                                  &payload, &payloadLength);
        if (unpacked < 0) {
            BFLog("boxd: trame v1 invalide");
            continue;
        }
        switch (command) {
        case BFV1_STATUS: {
            BFLog("boxd: STATUS reçu (%u octets)", (unsigned)payloadLength);
            int responseSize = BFV1PackStatus(transmitBuffer, sizeof(transmitBuffer), BFV1_STATUS,
                                              receivedReqId + 1, BFV1_STATUS_OK, "pong");
            if (responseSize > 0)
                (void)BFUdpSend(udpSocket, transmitBuffer, (size_t)responseSize,
                                (struct sockaddr *)&from, fromLength);
            break;
        }
        case BFV1_PUT: {
            BFLog("boxd: PUT %u octets", (unsigned)payloadLength);
            break;
        }
        default: {
            BFLog("boxd: commande inconnue: %u", command);
            break;
        }
        }
    }

    close(udpSocket);
    return 0;
}
