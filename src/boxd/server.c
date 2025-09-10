#include "box/BFBoxProtocol.h"
#include "box/BFCommon.h"
#include "box/BFDtls.h"
#include "box/BFUdp.h"
#include "box/BFUdpServer.h"

#include <arpa/inet.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

typedef struct ServerDtlsOptions {
    const char *certificateFile;
    const char *keyFile;
    const char *preShareKeyIdentity;
    const char *preShareKeyAscii;
} ServerDtlsOptions;

static void ServerPrintUsage(const char *program) {
    fprintf(stderr,
            "Usage: %s [--cert <pem>] [--key <pem>] [--pre-share-key-identity <id>]\n"
            "          [--pre-share-key <ascii>]\n",
            program);
}

static void ServerParseArgs(int argc, char **argv, ServerDtlsOptions *outOptions) {
    memset(outOptions, 0, sizeof(*outOptions));
    for (int i = 1; i < argc; ++i) {
        const char *arg = argv[i];
        if (strcmp(arg, "--help") == 0 || strcmp(arg, "-h") == 0) {
            ServerPrintUsage(argv[0]);
            exit(0);
        } else if (strcmp(arg, "--cert") == 0 && i + 1 < argc) {
            outOptions->certificateFile = argv[++i];
        } else if (strcmp(arg, "--key") == 0 && i + 1 < argc) {
            outOptions->keyFile = argv[++i];
        } else if (strcmp(arg, "--pre-share-key-identity") == 0 && i + 1 < argc) {
            outOptions->preShareKeyIdentity = argv[++i];
        } else if (strcmp(arg, "--pre-share-key") == 0 && i + 1 < argc) {
            outOptions->preShareKeyAscii = argv[++i];
        } else {
            BFError("Unknown option: %s", arg);
            ServerPrintUsage(argv[0]);
            exit(2);
        }
    }
}

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

    BFLog("boxd: datagram initial %zd octets reçu — %s", received, (char *)receiveBuffer);

    // 2) Handshake DTLS (optional config)
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
        dtls = BFDtlsServerNewEx(udpSocket, &config);
    } else {
        dtls = BFDtlsServerNew(udpSocket);
    }
    if (!dtls) {
        BFFatal("dtls_server_new");
    }

    if (BFDtlsHandshakeServer(dtls, &peer, peerLength) != BF_OK) {
        fprintf(stderr, "boxd: handshake DTLS a échoué (squelette)\n");
        BFDtlsFree(dtls);
        close(udpSocket);
        return 1;
    }

    // 3) Envoi d'un HELLO applicatif via DTLS
    uint8_t     transmitBuffer[BFMaxDatagram];
    const char *helloPayload = "hello from boxd";

    int packed = BFProtocolPack(transmitBuffer, sizeof(transmitBuffer), BFMessageHello,
                                helloPayload, (uint16_t)strlen(helloPayload));
    if (packed > 0)
        (void)BFDtlsSend(dtls, transmitBuffer, packed);

    // 4) Boucle simple: attendre PING et répondre PONG
    while (g_running) {
        int readCount = BFDtlsRecv(dtls, receiveBuffer, (int)sizeof(receiveBuffer));
        if (readCount <= 0) {
            // TODO: gérer WANT_READ/WRITE, timeouts, retransmissions
            break;
        }
        BFHeader       header;
        const uint8_t *payload = NULL;
        int unpacked = BFProtocolUnpack(receiveBuffer, (size_t)readCount, &header, &payload);
        if (unpacked < 0) {
            BFLog("boxd: trame invalide");
            continue;
        }
        switch (header.type) {
        case BFMessagePing: {
            BFLog("boxd: PING reçu (%u octets)", header.length);
            const char *pong = "pong";
            int k = BFProtocolPack(transmitBuffer, sizeof(transmitBuffer), BFMessagePong, pong,
                                   (uint16_t)strlen(pong));
            if (k > 0)
                (void)BFDtlsSend(dtls, transmitBuffer, k);
            break;
        }
        case BFMessageData: {
            BFLog("boxd: DATA %u octets", header.length);
            break;
        }
        default: {
            BFLog("boxd: type inconnu: %u", header.type);
            break;
        }
        }
    }

    BFDtlsFree(dtls);
    close(udpSocket);
    return 0;
}
