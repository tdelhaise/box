#include "BFNetworkNoiseInternal.h"

#include "box/BFAead.h"
#include "box/BFCommon.h"
#include "box/BFMemory.h"
#include "box/BFNetwork.h"

#if defined(HAVE_SODIUM)
#include <sodium.h>
#endif

#include <arpa/inet.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

typedef struct BFNetworkNoiseHandle {
    int udpFileDescriptor;
    struct {
        struct sockaddr_storage address;
        socklen_t               length;
    } peer;
    int      sodiumInitialized;
    uint8_t  aeadKey[BF_AEAD_KEY_BYTES];
    int      hasAeadKey;
    uint8_t  nonceSalt[16];
    uint64_t nextNonceCounter;
    uint8_t  peerSalt[16];
    int      hasPeerSalt;
    uint64_t recvWindowMax;
    uint64_t recvWindowBitmap;
} BFNetworkNoiseHandle;

static void derive_key_from_security(const BFNetworkSecurity *security, uint8_t *outKey,
                                     int *outHasKey) {
    *outHasKey = 0;
    if (!security || !security->preShareKey || security->preShareKeyLength == 0)
        return;
    memset(outKey, 0, BF_AEAD_KEY_BYTES);
    size_t copyLength = security->preShareKeyLength < BF_AEAD_KEY_BYTES
                            ? security->preShareKeyLength
                            : (size_t)BF_AEAD_KEY_BYTES;
    memcpy(outKey, security->preShareKey, copyLength);
    *outHasKey = 1;
}

static BFNetworkNoiseHandle *BFNetworkNoiseHandleNew(int                      udpFileDescriptor,
                                                     const BFNetworkSecurity *security) {
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
#endif
    derive_key_from_security(security, handle->aeadKey, &handle->hasAeadKey);
#if defined(HAVE_SODIUM)
    randombytes_buf(handle->nonceSalt, sizeof(handle->nonceSalt));
#else
    for (size_t index = 0; index < sizeof(handle->nonceSalt); ++index)
        handle->nonceSalt[index] = (uint8_t)(0x42U + (index * 7U));
#endif
    handle->nextNonceCounter = 1ULL;
    return handle;
}

static void BFNetworkNoiseHandleFree(BFNetworkNoiseHandle *handle) {
    if (!handle)
        return;
    memset(handle->aeadKey, 0, sizeof(handle->aeadKey));
    BFMemoryRelease(handle);
}

void *BFNetworkNoiseConnect(int udpFileDescriptor, const struct sockaddr *server,
                            socklen_t serverLength, const BFNetworkSecurity *security) {
    BFNetworkNoiseHandle *handle = BFNetworkNoiseHandleNew(udpFileDescriptor, security);
    if (!handle)
        return NULL;
    memset(&handle->peer, 0, sizeof(handle->peer));
    if (server && serverLength <= (socklen_t)sizeof(handle->peer.address)) {
        memcpy(&handle->peer.address, server, (size_t)serverLength);
        handle->peer.length = serverLength;
    }
    if (!handle->hasAeadKey) {
        BFWarn("BFNetwork Noise: no pre-shared key; encryption disabled for skeleton");
    }
    return handle;
}

void *BFNetworkNoiseAccept(int udpFileDescriptor, const struct sockaddr_storage *peer,
                           socklen_t peerLength, const BFNetworkSecurity *security) {
    BFNetworkNoiseHandle *handle = BFNetworkNoiseHandleNew(udpFileDescriptor, security);
    if (!handle)
        return NULL;
    memset(&handle->peer, 0, sizeof(handle->peer));
    if (peer && peerLength <= (socklen_t)sizeof(handle->peer.address)) {
        memcpy(&handle->peer.address, peer, (size_t)peerLength);
        handle->peer.length = peerLength;
    }
    if (!handle->hasAeadKey) {
        BFWarn("BFNetwork Noise: no pre-shared key; encryption disabled for skeleton");
    }
    return handle;
}

static void build_nonce(uint8_t nonce[BF_AEAD_NONCE_BYTES], const uint8_t salt[16],
                        uint64_t counter) {
    memcpy(nonce, salt, 16);
    nonce[16] = (uint8_t)((counter >> 56) & 0xFFU);
    nonce[17] = (uint8_t)((counter >> 48) & 0xFFU);
    nonce[18] = (uint8_t)((counter >> 40) & 0xFFU);
    nonce[19] = (uint8_t)((counter >> 32) & 0xFFU);
    nonce[20] = (uint8_t)((counter >> 24) & 0xFFU);
    nonce[21] = (uint8_t)((counter >> 16) & 0xFFU);
    nonce[22] = (uint8_t)((counter >> 8) & 0xFFU);
    nonce[23] = (uint8_t)((counter) & 0xFFU);
}

// Frame: ['N''Z' 0x01 0x00] [24-byte nonce] [ciphertext]
int BFNetworkNoiseSend(void *handlePointer, const void *buffer, int length) {
    BFNetworkNoiseHandle *handle = (BFNetworkNoiseHandle *)handlePointer;
    if (!handle || !buffer || length < 0)
        return BF_ERR;
    if (!handle->hasAeadKey)
        return BF_ERR;
    const uint8_t *plaintext           = (const uint8_t *)buffer;
    uint8_t        associatedHeader[4] = {'N', 'Z', 1U, 0U};
    uint8_t        nonce[BF_AEAD_NONCE_BYTES];
    build_nonce(nonce, handle->nonceSalt, handle->nextNonceCounter++);
    uint32_t ciphertextLengthExpected = (uint32_t)length + (uint32_t)BF_AEAD_ABYTES;
    uint32_t frameOverhead            = 4U + (uint32_t)BF_AEAD_NONCE_BYTES;
    if ((size_t)(ciphertextLengthExpected + frameOverhead) > BFMaxDatagram)
        return BF_ERR;
    uint8_t frameBuffer[BFMaxDatagram];
    memcpy(frameBuffer, associatedHeader, sizeof(associatedHeader));
    memcpy(frameBuffer + 4, nonce, sizeof(nonce));
    uint32_t producedLength = 0;
    int      enc = BFAeadEncrypt(handle->aeadKey, nonce, associatedHeader, sizeof(associatedHeader),
                                 plaintext, (uint32_t)length, frameBuffer + 4 + sizeof(nonce),
                                 (uint32_t)(sizeof(frameBuffer) - 4U - (uint32_t)sizeof(nonce)),
                                 &producedLength);
    if (enc != BF_OK)
        return BF_ERR;
    size_t  frameLength = 4U + (size_t)sizeof(nonce) + (size_t)producedLength;
    ssize_t sent        = sendto(handle->udpFileDescriptor, frameBuffer, frameLength, 0,
                                 (struct sockaddr *)&handle->peer.address, handle->peer.length);
    if (sent < 0)
        return BF_ERR;
    return (int)length;
}

int BFNetworkNoiseRecv(void *handlePointer, void *buffer, int length) {
    BFNetworkNoiseHandle *handle = (BFNetworkNoiseHandle *)handlePointer;
    if (!handle || !buffer || length <= 0)
        return BF_ERR;
    if (!handle->hasAeadKey)
        return BF_ERR;
    uint8_t                 datagram[BFMaxDatagram];
    struct sockaddr_storage fromAddress;
    socklen_t               fromLength = sizeof(fromAddress);
    ssize_t received = recvfrom(handle->udpFileDescriptor, datagram, sizeof(datagram), 0,
                                (struct sockaddr *)&fromAddress, &fromLength);
    if (received <= 0)
        return BF_ERR;
    if (received < (ssize_t)(4 + BF_AEAD_NONCE_BYTES + BF_AEAD_ABYTES))
        return BF_ERR;
    if (datagram[0] != 'N' || datagram[1] != 'Z' || datagram[2] != 1U)
        return BF_ERR;
    const uint8_t *associatedHeader = datagram;
    const uint8_t *nonce            = datagram + 4;
    const uint8_t *ciphertext       = datagram + 4 + BF_AEAD_NONCE_BYTES;
    uint32_t       ciphertextLength = (uint32_t)(received - (4 + BF_AEAD_NONCE_BYTES));
    if (ciphertextLength > (uint32_t)(length + BF_AEAD_ABYTES))
        return BF_ERR;
    // Replay checks: salt consistency and sliding window over counters
    uint64_t counter = ((uint64_t)nonce[16] << 56) | ((uint64_t)nonce[17] << 48) |
                       ((uint64_t)nonce[18] << 40) | ((uint64_t)nonce[19] << 32) |
                       ((uint64_t)nonce[20] << 24) | ((uint64_t)nonce[21] << 16) |
                       ((uint64_t)nonce[22] << 8) | ((uint64_t)nonce[23]);
    if (!handle->hasPeerSalt) {
        memcpy(handle->peerSalt, nonce, 16);
        handle->hasPeerSalt      = 1;
        handle->recvWindowMax    = 0;
        handle->recvWindowBitmap = 0;
    } else if (memcmp(handle->peerSalt, nonce, 16) != 0) {
        return BF_ERR;
    }
    if (handle->recvWindowMax != 0 && counter <= handle->recvWindowMax) {
        uint64_t delta = handle->recvWindowMax - counter;
        if (delta >= 64U)
            return BF_ERR; // too old
        uint64_t mask = (uint64_t)1 << delta;
        if ((handle->recvWindowBitmap & mask) != 0)
            return BF_ERR; // replayed
    }
    uint32_t plaintextLength = 0;
    int      dec =
        BFAeadDecrypt(handle->aeadKey, nonce, associatedHeader, 4, ciphertext, ciphertextLength,
                      (uint8_t *)buffer, (uint32_t)length, &plaintextLength);
    if (dec != BF_OK)
        return BF_ERR;
    // Update window after successful decrypt
    if (handle->recvWindowMax == 0 || counter > handle->recvWindowMax) {
        if (handle->recvWindowMax == 0) {
            handle->recvWindowBitmap = 1ULL; // mark newest
        } else {
            uint64_t shift = counter - handle->recvWindowMax;
            if (shift >= 64U) {
                handle->recvWindowBitmap = 0;
            } else {
                handle->recvWindowBitmap <<= shift;
            }
            handle->recvWindowBitmap |= 1ULL; // mark newest
        }
        handle->recvWindowMax = counter;
    } else {
        uint64_t delta = handle->recvWindowMax - counter;
        handle->recvWindowBitmap |= ((uint64_t)1 << delta);
    }
    return (int)plaintextLength;
}

void BFNetworkNoiseClose(void *handlePointer) {
    BFNetworkNoiseHandle *handle = (BFNetworkNoiseHandle *)handlePointer;
    BFNetworkNoiseHandleFree(handle);
}
