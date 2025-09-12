#include "box/BFNetwork.h"
#include "box/BFCommon.h"

#include <arpa/inet.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int create_udp_server(struct sockaddr_in *outAddress, int *outErrorCode) {
    int                 fileDescriptor = (int)socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in  address;
    memset(&address, 0, sizeof(address));
    address.sin_family      = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port        = htons(0);
    if (bind(fileDescriptor, (struct sockaddr *)&address, sizeof(address)) != 0) {
        if (outErrorCode)
            *outErrorCode = errno;
        close(fileDescriptor);
        return -1;
    }
    socklen_t addressLength = sizeof(address);
    if (getsockname(fileDescriptor, (struct sockaddr *)&address, &addressLength) != 0) {
        if (outErrorCode)
            *outErrorCode = errno;
        close(fileDescriptor);
        return -1;
    }
    *outAddress = address;
    if (outErrorCode)
        *outErrorCode = 0;
    return fileDescriptor;
}

static int create_udp_client(const struct sockaddr_in *serverAddress) {
    (void)serverAddress;
    int fd = (int)socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        perror("socket");
        return -1;
    }
    return fd;
}

int main(void) {
    struct sockaddr_in serverBindAddress;
    int                lastErrorCode = 0;
    int                serverSocket = create_udp_server(&serverBindAddress, &lastErrorCode);
    if (serverSocket < 0) {
        fprintf(stderr, "Skipping test_BFNetworkNoise: cannot bind UDP socket in this environment\n");
        return 0; // skip gracefully in restricted sandboxes (CI will run it normally)
    }

    int clientSocket = create_udp_client(&serverBindAddress);
    if (clientSocket < 0) {
        close(serverSocket);
        return 1;
    }

    // 1) Send initial clear datagram so server learns peer address
    const char *initialHello = "hello";
    if (sendto(clientSocket, initialHello, strlen(initialHello), 0, (struct sockaddr *)&serverBindAddress,
               sizeof(serverBindAddress)) < 0) {
        perror("sendto initial");
        close(clientSocket);
        close(serverSocket);
        return 1;
    }

    struct sockaddr_storage learnedPeerAddress;
    socklen_t               learnedPeerLength = sizeof(learnedPeerAddress);
    uint8_t                 receiveBuffer[64];
    (void)recvfrom(serverSocket, receiveBuffer, sizeof(receiveBuffer), 0,
                   (struct sockaddr *)&learnedPeerAddress, &learnedPeerLength);

    // 2) Build Noise connections with a pre-shared key
    BFNetworkSecurity serverSecurity;
    memset(&serverSecurity, 0, sizeof(serverSecurity));
    serverSecurity.preShareKey       = (const unsigned char *)"psk123";
    serverSecurity.preShareKeyLength = 6U;

    BFNetworkSecurity clientSecurity = serverSecurity;

    BFNetworkConnection *serverConn = BFNetworkAcceptDatagram(
        BFNetworkTransportNOISE, serverSocket, &learnedPeerAddress, learnedPeerLength, &serverSecurity);
    if (!serverConn) {
        fprintf(stderr, "server noise accept failed\n");
        close(clientSocket);
        close(serverSocket);
        return 1;
    }

    BFNetworkConnection *clientConn = BFNetworkConnectDatagram(
        BFNetworkTransportNOISE, clientSocket, (struct sockaddr *)&serverBindAddress,
        (socklen_t)sizeof(serverBindAddress), &clientSecurity);
    if (!clientConn) {
        fprintf(stderr, "client noise connect failed\n");
        BFNetworkClose(serverConn);
        close(clientSocket);
        close(serverSocket);
        return 1;
    }

    // Positive case: client sends ping, server receives and replies, client receives pong
    const char *pingText = "ping";
    if (BFNetworkSend(clientConn, pingText, (int)strlen(pingText)) <= 0) {
        fprintf(stderr, "send ping failed\n");
        BFNetworkClose(clientConn);
        BFNetworkClose(serverConn);
        close(clientSocket);
        close(serverSocket);
        return 1;
    }
    char serverPlaintext[64];
    int  serverRead = BFNetworkRecv(serverConn, serverPlaintext, (int)sizeof(serverPlaintext));
    if (serverRead != 4 || memcmp(serverPlaintext, "ping", 4) != 0) {
        fprintf(stderr, "server expected ping, got %d\n", serverRead);
        BFNetworkClose(clientConn);
        BFNetworkClose(serverConn);
        close(clientSocket);
        close(serverSocket);
        return 1;
    }
    const char *pongText = "pong";
    if (BFNetworkSend(serverConn, pongText, (int)strlen(pongText)) <= 0) {
        fprintf(stderr, "send pong failed\n");
        BFNetworkClose(clientConn);
        BFNetworkClose(serverConn);
        close(clientSocket);
        close(serverSocket);
        return 1;
    }
    char clientPlaintext[64];
    int  clientRead = BFNetworkRecv(clientConn, clientPlaintext, (int)sizeof(clientPlaintext));
    if (clientRead != 4 || memcmp(clientPlaintext, "pong", 4) != 0) {
        fprintf(stderr, "client expected pong, got %d\n", clientRead);
        BFNetworkClose(clientConn);
        BFNetworkClose(serverConn);
        close(clientSocket);
        close(serverSocket);
        return 1;
    }

    // Negative header case: send clear junk directly; expect BF_ERR on server recv
    (void)sendto(clientSocket, "junk", 4, 0, (struct sockaddr *)&serverBindAddress,
                 sizeof(serverBindAddress));
    int negativeRead = BFNetworkRecv(serverConn, serverPlaintext, (int)sizeof(serverPlaintext));
    if (negativeRead >= 0) {
        fprintf(stderr, "expected error on bad header\n");
        BFNetworkClose(clientConn);
        BFNetworkClose(serverConn);
        close(clientSocket);
        close(serverSocket);
        return 1;
    }

    // MAC failure case: wrong PSK on server
    BFNetworkSecurity wrongServerSecurity = {0};
    wrongServerSecurity.preShareKey       = (const unsigned char *)"wrong";
    wrongServerSecurity.preShareKeyLength = 5U;
    BFNetworkConnection *serverWrong = BFNetworkAcceptDatagram(
        BFNetworkTransportNOISE, serverSocket, &learnedPeerAddress, learnedPeerLength,
        &wrongServerSecurity);
    if (!serverWrong) {
        fprintf(stderr, "server wrong accept failed\n");
        BFNetworkClose(clientConn);
        BFNetworkClose(serverConn);
        close(clientSocket);
        close(serverSocket);
        return 1;
    }
    const char *textHello = "hello";
    (void)BFNetworkSend(clientConn, textHello, (int)strlen(textHello));
    int wrongRead = BFNetworkRecv(serverWrong, serverPlaintext, (int)sizeof(serverPlaintext));
    // With wrong key, decryption must fail
    if (wrongRead >= 0) {
        fprintf(stderr, "expected decrypt failure with wrong key\n");
        BFNetworkClose(serverWrong);
        BFNetworkClose(clientConn);
        BFNetworkClose(serverConn);
        close(clientSocket);
        close(serverSocket);
        return 1;
    }
    BFNetworkClose(serverWrong);

    BFNetworkClose(clientConn);
    BFNetworkClose(serverConn);
    close(clientSocket);
    close(serverSocket);
    return 0;
}
