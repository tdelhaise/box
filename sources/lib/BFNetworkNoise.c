#include "BFNetworkNoiseInternal.h"

#include "BFAead.h"
#include "BFCommon.h"
#include "BFMemory.h"
#include "BFNetwork.h"

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
    int     sodiumInitialized;
    uint8_t aeadKey[BF_AEAD_KEY_BYTES];
    int     hasAeadKey;
    // Transcript hash (scaffold) binding pattern, prologue, identities
    uint8_t  transcriptHash[32];
    int      hasTranscriptHash;
    uint8_t  nonceSalt[16];
    uint64_t nextNonceCounter;
    uint8_t  peerSalt[16];
    int      hasPeerSalt;
    uint64_t receiveWindowMax;
    uint64_t receiveWindowBitmap;
#ifdef BF_NOISE_TEST_HOOKS
    size_t  replayFrameLength;
    uint8_t replayFrame[BF_MACRO_MAX_DATAGRAM_SIZE];
    size_t  lastFrameLength;
    uint8_t lastFrame[BF_MACRO_MAX_DATAGRAM_SIZE];
#endif
} BFNetworkNoiseHandle;

// derive_transcript_and_session_key
// deriveTranscriptAndSessionKey
static void deriveTranscriptAndSessionKey(const BFNetworkSecurity *security, uint8_t *outKey, int *outHasKey, uint8_t *outTranscript, int *outHasTranscript) {
    *outHasKey        = 0;
    *outHasTranscript = 0;
    if (!security) {
        return;
    }
#if defined(HAVE_SODIUM)
    // Build a simple transcript hash that binds pattern + identities + prologue.
    crypto_generichash_state state;
    (void)crypto_generichash_init(&state, NULL, 0U, sizeof(outTranscript[0]) * 32U);
    const char *label = "box/noise/scaffold/v1";
    (void)crypto_generichash_update(&state, (const unsigned char *)label, strlen(label));
    unsigned char patternByte = 0x00U;
    if (security->hasNoiseHandshakePattern) {
        if (security->noiseHandshakePattern == BFNoiseHandshakePatternNK) {
            patternByte = 0x01U;
        } else if (security->noiseHandshakePattern == BFNoiseHandshakePatternIK) {
            patternByte = 0x02U;
        }
    }
    (void)crypto_generichash_update(&state, &patternByte, 1U);
    if (security->noisePrologue && *security->noisePrologue) {
        (void)crypto_generichash_update(&state, (const unsigned char *)security->noisePrologue, strlen(security->noisePrologue));
    }
    if (security->noiseServerStaticPublicKey && security->noiseServerStaticPublicKeyLength >= 32U) {
        (void)crypto_generichash_update(&state, security->noiseServerStaticPublicKey, 32U);
    }
    if (security->noiseClientStaticPublicKey && security->noiseClientStaticPublicKeyLength >= 32U) {
        (void)crypto_generichash_update(&state, security->noiseClientStaticPublicKey, 32U);
    }
    unsigned char transcript[32];
    (void)crypto_generichash_final(&state, transcript, sizeof(transcript));
    memcpy(outTranscript, transcript, sizeof(transcript));
    *outHasTranscript = 1;

    // Derive a session key from the transcript, keyed with a secret if provided.
    // Require a secret: either pre-shared key or client static private key (for IK).
    const unsigned char *secretKeyMaterial     = NULL;
    size_t               secretKeyMaterialSize = 0U;
    if (security->preShareKey && security->preShareKeyLength > 0) {
        secretKeyMaterial     = security->preShareKey;
        secretKeyMaterialSize = security->preShareKeyLength;
    } else if (security->noiseClientStaticPrivateKey && security->noiseClientStaticPrivateKeyLength >= 32U) {
        secretKeyMaterial     = security->noiseClientStaticPrivateKey;
        secretKeyMaterialSize = 32U;
    }
    if (!secretKeyMaterial || secretKeyMaterialSize == 0U) {
        // No secret -> do not enable encryption in scaffold
        return;
    }
    unsigned char aeadKey[BF_AEAD_KEY_BYTES];
    crypto_generichash(aeadKey, sizeof(aeadKey), transcript, sizeof(transcript), secretKeyMaterial, (unsigned long long)secretKeyMaterialSize);
    memcpy(outKey, aeadKey, sizeof(aeadKey));
    *outHasKey = 1;
#else
    // Without libsodium, keep existing PSK behavior as a gate and fill a deterministic key.
    *outHasKey        = 0;
    *outHasTranscript = 0;
    if (!security->preShareKey || security->preShareKeyLength == 0) {
        return;
    }
    memset(outKey, 0, BF_AEAD_KEY_BYTES);
    size_t copyLength = security->preShareKeyLength < BF_AEAD_KEY_BYTES ? security->preShareKeyLength : (size_t)BF_AEAD_KEY_BYTES;
    memcpy(outKey, security->preShareKey, copyLength);
    *outHasKey = 1;
#endif
}

static BFNetworkNoiseHandle *BFNetworkNoiseHandleNew(int udpFileDescriptor, const BFNetworkSecurity *security) {
    BFNetworkNoiseHandle *handle = (BFNetworkNoiseHandle *)BFMemoryAllocate(sizeof(BFNetworkNoiseHandle));
    if (!handle) {
        return NULL;
    }
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
    deriveTranscriptAndSessionKey(security, handle->aeadKey, &handle->hasAeadKey, handle->transcriptHash, &handle->hasTranscriptHash);
#if 1
    if (security) {
        const char *patternName = "unknown";
        if (security->hasNoiseHandshakePattern) {
            patternName = (security->noiseHandshakePattern == BFNoiseHandshakePatternNK) ? "nk" : (security->noiseHandshakePattern == BFNoiseHandshakePatternIK) ? "ik" : "unknown";
        }
        BFLog("BFNetwork Noise: scaffold pattern=%s transcript=%s key=%s%s", patternName, handle->hasTranscriptHash ? "on" : "off", handle->hasAeadKey ? "on" : "off", (security->noisePrologue && *security->noisePrologue) ? " prologue" : "");
    }
#endif
#if defined(HAVE_SODIUM)
    randombytes_buf(handle->nonceSalt, sizeof(handle->nonceSalt));
#else
    for (size_t index = 0; index < sizeof(handle->nonceSalt); ++index) {
        handle->nonceSalt[index] = (uint8_t)(0x42U + (index * 7U));
    }
#endif
    handle->nextNonceCounter = 1ULL;
    return handle;
}

static void BFNetworkNoiseHandleFree(BFNetworkNoiseHandle *handle) {
    if (!handle) {
        return;
    }
    memset(handle->aeadKey, 0, sizeof(handle->aeadKey));
    BFMemoryRelease(handle);
}

void *BFNetworkNoiseConnect(int udpFileDescriptor, const struct sockaddr *server, socklen_t serverLength, const BFNetworkSecurity *security) {
    BFNetworkNoiseHandle *handle = BFNetworkNoiseHandleNew(udpFileDescriptor, security);
    if (!handle) {
        return NULL;
    }
    memset(&handle->peer, 0, sizeof(handle->peer));
    if (server && serverLength <= (socklen_t)sizeof(handle->peer.address)) {
        memcpy(&handle->peer.address, server, (size_t)serverLength);
        handle->peer.length = serverLength;
    }
    if (!handle->hasAeadKey) {
        BFWarn("BFNetwork Noise: no session key; transport disabled (scaffold)");
    }
    return handle;
}

void *BFNetworkNoiseAccept(int udpFileDescriptor, const struct sockaddr_storage *peer, socklen_t peerLength, const BFNetworkSecurity *security) {
    BFNetworkNoiseHandle *handle = BFNetworkNoiseHandleNew(udpFileDescriptor, security);
    if (!handle) {
        return NULL;
    }
    memset(&handle->peer, 0, sizeof(handle->peer));
    if (peer && peerLength <= (socklen_t)sizeof(handle->peer.address)) {
        memcpy(&handle->peer.address, peer, (size_t)peerLength);
        handle->peer.length = peerLength;
    }
    if (!handle->hasAeadKey) {
        BFWarn("BFNetwork Noise: no session key; transport disabled (scaffold)");
    }
    return handle;
}

static void buildNonce(uint8_t nonce[BF_AEAD_NONCE_BYTES], const uint8_t salt[16], uint64_t counter) {
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
    if (!handle || !buffer || length < 0 || !handle->hasAeadKey) {
        return BF_ERR;
    }
    const uint8_t *plaintext                                         = (const uint8_t *)buffer;
    uint8_t        associatedHeader[BF_MACRO_SIZE_ASSOCIATED_HEADER] = {'N', 'Z', 1U, 0U};
    uint8_t        nonce[BF_AEAD_NONCE_BYTES];
    size_t         sizeOfAssociatedHeader = sizeof(associatedHeader);
    size_t         sizeOfNonce            = sizeof(nonce);
    buildNonce(nonce, handle->nonceSalt, handle->nextNonceCounter++);
    uint32_t ciphertextLengthExpected = (uint32_t)length + (uint32_t)BF_AEAD_ABYTES;
    uint32_t frameOverhead            = 4U + (uint32_t)BF_AEAD_NONCE_BYTES;
    if ((size_t)(ciphertextLengthExpected + frameOverhead) > BFGlobalMaxDatagram) {
        return BF_ERR;
    }
    uint8_t frameBuffer[BF_MACRO_MAX_DATAGRAM_SIZE];
    memcpy(frameBuffer, associatedHeader, sizeOfAssociatedHeader);
    memcpy(frameBuffer + sizeOfAssociatedHeader, nonce, sizeOfNonce);
    uint32_t producedLength = 0;
    int      enc            = BFAeadEncrypt(handle->aeadKey, nonce, associatedHeader, sizeof(associatedHeader), plaintext, (uint32_t)length, frameBuffer + 4 + sizeof(nonce), (uint32_t)(sizeof(frameBuffer) - 4U - (uint32_t)sizeof(nonce)), &producedLength);
    if (enc != BF_OK) {
        return BF_ERR;
    }
    BFDebug("BFNetworkNoiseSend: producedLength: %d", producedLength);
    size_t frameLength = 4U + (size_t)sizeof(nonce) + (size_t)producedLength;
#ifdef BF_NOISE_TEST_HOOKS
    if (handle->lastFrameLength > 0 && frameLength <= sizeof(handle->replayFrame)) {
        memcpy(handle->replayFrame, handle->lastFrame, handle->lastFrameLength);
        handle->replayFrameLength = handle->lastFrameLength;
    }
    if (frameLength <= sizeof(handle->lastFrame)) {
        memcpy(handle->lastFrame, frameBuffer, frameLength);
        handle->lastFrameLength = frameLength;
    } else {
        handle->lastFrameLength   = 0;
        handle->replayFrameLength = 0;
    }
#endif
    ssize_t sent = sendto(handle->udpFileDescriptor, frameBuffer, frameLength, 0, (struct sockaddr *)&handle->peer.address, handle->peer.length);
    if (sent < 0) {
        return BF_ERR;
    } else {
        BFDebug("BFNetworkNoiseSend: sent: %d", sent);
    }

    return (int)length;
}

int BFNetworkNoiseReceive(void *handlePointer, void *buffer, int length) {
    BFNetworkNoiseHandle *handle = (BFNetworkNoiseHandle *)handlePointer;
    if (!handle || !buffer || length <= 0) {
        return BF_ERR;
    }
    if (!handle->hasAeadKey) {
        return BF_ERR;
    }
    uint8_t                 datagram[BF_MACRO_MAX_DATAGRAM_SIZE];
    struct sockaddr_storage fromAddress;
    socklen_t               fromLength = sizeof(fromAddress);
    ssize_t                 received   = recvfrom(handle->udpFileDescriptor, datagram, sizeof(datagram), 0, (struct sockaddr *)&fromAddress, &fromLength);
    if (received <= 0) {
        return BF_ERR;
    }
    if (received < (ssize_t)(4 + BF_AEAD_NONCE_BYTES + BF_AEAD_ABYTES)) {
        return BF_ERR;
    }
    if (datagram[0] != 'N' || datagram[1] != 'Z' || datagram[2] != 1U) {
        return BF_ERR;
    }
    const uint8_t *associatedHeader = datagram;
    const uint8_t *nonce            = datagram + 4;
    const uint8_t *ciphertext       = datagram + 4 + BF_AEAD_NONCE_BYTES;
    uint32_t       ciphertextLength = (uint32_t)(received - (4 + BF_AEAD_NONCE_BYTES));
    if (ciphertextLength > (uint32_t)(length + BF_AEAD_ABYTES)) {
        return BF_ERR;
    }
    // Replay checks: salt consistency and sliding window over counters
    uint64_t counter = ((uint64_t)nonce[16] << 56) | ((uint64_t)nonce[17] << 48) | ((uint64_t)nonce[18] << 40) | ((uint64_t)nonce[19] << 32) | ((uint64_t)nonce[20] << 24) | ((uint64_t)nonce[21] << 16) | ((uint64_t)nonce[22] << 8) | ((uint64_t)nonce[23]);
    if (!handle->hasPeerSalt) {
        memcpy(handle->peerSalt, nonce, 16);
        handle->hasPeerSalt         = 1;
        handle->receiveWindowMax    = 0;
        handle->receiveWindowBitmap = 0;
    } else if (memcmp(handle->peerSalt, nonce, 16) != 0) {
        return BF_ERR;
    }
    if (handle->receiveWindowMax != 0 && counter <= handle->receiveWindowMax) {
        uint64_t delta = handle->receiveWindowMax - counter;
        if (delta >= 64U) {
            return BF_ERR; // too old
        }
        uint64_t mask = (uint64_t)1 << delta;
        if ((handle->receiveWindowBitmap & mask) != 0) {
            return BF_ERR; // replayed
        }
    }
    uint32_t plaintextLength = 0;
    int      dec             = BFAeadDecrypt(handle->aeadKey, nonce, associatedHeader, 4, ciphertext, ciphertextLength, (uint8_t *)buffer, (uint32_t)length, &plaintextLength);
    if (dec != BF_OK) {
        return BF_ERR;
    }
    // Update window after successful decrypt
    if (handle->receiveWindowMax == 0 || counter > handle->receiveWindowMax) {
        if (handle->receiveWindowMax == 0) {
            handle->receiveWindowBitmap = 1ULL; // mark newest
        } else {
            uint64_t shift = counter - handle->receiveWindowMax;
            if (shift >= 64U) {
                handle->receiveWindowBitmap = 0;
            } else {
                handle->receiveWindowBitmap <<= shift;
            }
            handle->receiveWindowBitmap |= 1ULL; // mark newest
        }
        handle->receiveWindowMax = counter;
    } else {
        uint64_t delta = handle->receiveWindowMax - counter;
        handle->receiveWindowBitmap |= ((uint64_t)1 << delta);
    }
    return (int)plaintextLength;
}

void BFNetworkNoiseClose(void *handlePointer) {
    BFNetworkNoiseHandle *handle = (BFNetworkNoiseHandle *)handlePointer;
    BFNetworkNoiseHandleFree(handle);
}

#ifdef BF_NOISE_TEST_HOOKS
int BFNetworkNoiseDebugResendLastFrame(void *handlePointer) {
    BFNetworkNoiseHandle *handle = (BFNetworkNoiseHandle *)handlePointer;
    if (!handle) {
        return BF_ERR;
    }
    const uint8_t *framePointer = NULL;
    size_t         frameLength  = 0;
    if (handle->replayFrameLength > 0) {
        framePointer = handle->replayFrame;
        frameLength  = handle->replayFrameLength;
    } else if (handle->lastFrameLength > 0) {
        framePointer = handle->lastFrame;
        frameLength  = handle->lastFrameLength;
    }
    if (!framePointer || frameLength == 0) {
        return BF_ERR;
    }
    ssize_t sent = sendto(handle->udpFileDescriptor, framePointer, frameLength, 0, (struct sockaddr *)&handle->peer.address, handle->peer.length);
    if (sent < 0) {
        return BF_ERR;
    }
    return (int)sent;
}
#endif
