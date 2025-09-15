#include "BFAead.h"
#include "BFCommon.h"

#if defined(HAVE_SODIUM)
#include <sodium.h>
#endif

int BFAeadEncrypt(const uint8_t *key, const uint8_t *nonce, const uint8_t *associatedData, uint32_t associatedDataLength, const uint8_t *plaintext, uint32_t plaintextLength, uint8_t *ciphertext, uint32_t ciphertextBufferLength, uint32_t *outCiphertextLength) {
#if defined(HAVE_SODIUM)
    if (!key || !nonce || (!plaintext && plaintextLength > 0) || !ciphertext || !outCiphertextLength)
        return BF_ERR;
    unsigned long long producedLength = 0;
    if (ciphertextBufferLength < plaintextLength + (uint32_t)BF_AEAD_ABYTES)
        return BF_ERR;
    int rc = crypto_aead_xchacha20poly1305_ietf_encrypt(ciphertext, &producedLength, plaintext, (unsigned long long)plaintextLength, associatedData, (unsigned long long)associatedDataLength, NULL /* nsec */, nonce, key);
    if (rc != 0)
        return BF_ERR;
    *outCiphertextLength = (uint32_t)producedLength;
    return BF_OK;
#else
    (void)key;
    (void)nonce;
    (void)associatedData;
    (void)associatedDataLength;
    (void)plaintext;
    (void)plaintextLength;
    (void)ciphertext;
    (void)ciphertextBufferLength;
    (void)outCiphertextLength;
    return BF_ERR;
#endif
}

int BFAeadDecrypt(const uint8_t *key, const uint8_t *nonce, const uint8_t *associatedData, uint32_t associatedDataLength, const uint8_t *ciphertext, uint32_t ciphertextLength, uint8_t *plaintext, uint32_t plaintextBufferLength, uint32_t *outPlaintextLength) {
#if defined(HAVE_SODIUM)
    if (!key || !nonce || (!ciphertext && ciphertextLength > 0) || !plaintext || !outPlaintextLength)
        return BF_ERR;
    if (ciphertextLength < (uint32_t)BF_AEAD_ABYTES)
        return BF_ERR;
    unsigned long long producedLength = 0;
    if (plaintextBufferLength + (uint32_t)BF_AEAD_ABYTES < ciphertextLength) // prevent underflow
        return BF_ERR;
    int rc = crypto_aead_xchacha20poly1305_ietf_decrypt(plaintext, &producedLength, NULL /* nsec */, ciphertext, (unsigned long long)ciphertextLength, associatedData, (unsigned long long)associatedDataLength, nonce, key);
    if (rc != 0)
        return BF_ERR;
    *outPlaintextLength = (uint32_t)producedLength;
    return BF_OK;
#else
    (void)key;
    (void)nonce;
    (void)associatedData;
    (void)associatedDataLength;
    (void)ciphertext;
    (void)ciphertextLength;
    (void)plaintext;
    (void)plaintextBufferLength;
    (void)outPlaintextLength;
    return BF_ERR;
#endif
}
