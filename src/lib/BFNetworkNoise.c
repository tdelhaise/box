#include "BFNetworkNoiseInternal.h"

#include "box/BFCommon.h"
#include "box/BFMemory.h"

#if defined(HAVE_SODIUM)
#include <sodium.h>
#endif

#include <string.h>

typedef struct BFNetworkNoiseHandle {
    int         udpFileDescriptor;
    struct {
        struct sockaddr_storage address;
        socklen_t               length;
    } peer;
    int sodiumInitialized;
} BFNetworkNoiseHandle;

static BFNetworkNoiseHandle *BFNetworkNoiseHandleNew(int udpFileDescriptor) {
    BFNetworkNoiseHandle *handle =
        (BFNetworkNoiseHandle *)BFMemoryAllocate(sizeof(BFNetworkNoiseHandle));
    if (!handle)
        return NULL;
    memset(handle, 0, sizeof(*handle));
    handle->udpFileDescriptor = udpFileDescriptor;
#if defined(HAVE_SODIUM)
    if (sodium_init() >= 0) {
        handle->sodiumInitialized = 1;
    } else {
        BFWarn("BFNetwork Noise: sodium_init failed");
        handle->sodiumInitialized = 0;
    }
#else
    BFWarn("BFNetwork Noise: libsodium not available (HAVE_SODIUM=0)");
#endif
    return handle;
}

static void BFNetworkNoiseHandleFree(BFNetworkNoiseHandle *handle) {
    if (!handle)
        return;
    BFMemoryRelease(handle);
}

void *BFNetworkNoiseConnect(int udpFileDescriptor, const struct sockaddr *server,
                            socklen_t serverLength, const BFNetworkSecurity *security) {
    (void)security;
    BFNetworkNoiseHandle *handle = BFNetworkNoiseHandleNew(udpFileDescriptor);
    if (!handle)
        return NULL;
    memset(&handle->peer, 0, sizeof(handle->peer));
    if (server && serverLength <= (socklen_t)sizeof(handle->peer.address)) {
        memcpy(&handle->peer.address, server, (size_t)serverLength);
        handle->peer.length = serverLength;
    }
    BFWarn("BFNetwork Noise: connect skeleton initialized (encryption not implemented yet)");
    return handle;
}

void *BFNetworkNoiseAccept(int udpFileDescriptor, const struct sockaddr_storage *peer,
                           socklen_t peerLength, const BFNetworkSecurity *security) {
    (void)security;
    BFNetworkNoiseHandle *handle = BFNetworkNoiseHandleNew(udpFileDescriptor);
    if (!handle)
        return NULL;
    memset(&handle->peer, 0, sizeof(handle->peer));
    if (peer && peerLength <= (socklen_t)sizeof(handle->peer.address)) {
        memcpy(&handle->peer.address, peer, (size_t)peerLength);
        handle->peer.length = peerLength;
    }
    BFWarn("BFNetwork Noise: accept skeleton initialized (encryption not implemented yet)");
    return handle;
}

int BFNetworkNoiseSend(void *h, const void *buffer, int length) {
    (void)h;
    (void)buffer;
    (void)length;
    BFWarn("BFNetwork Noise: send not implemented yet");
    return BF_ERR;
}

int BFNetworkNoiseRecv(void *h, void *buffer, int length) {
    (void)h;
    (void)buffer;
    (void)length;
    BFWarn("BFNetwork Noise: recv not implemented yet");
    return BF_ERR;
}

void BFNetworkNoiseClose(void *h) {
    BFNetworkNoiseHandle *handle = (BFNetworkNoiseHandle *)h;
    BFNetworkNoiseHandleFree(handle);
}

