#include "box/BFAead.h"
#include <stdio.h>
#include <string.h>

int main(void) {
#if defined(HAVE_SODIUM)
    const char *message = "hello aead";
    uint8_t     key[BF_AEAD_KEY_BYTES];
    uint8_t     nonce[BF_AEAD_NONCE_BYTES];

    // Simple deterministic key/nonce for test (not secure)
    for (size_t index = 0; index < sizeof key; ++index)
        key[index] = (uint8_t)index;
    for (size_t index = 0; index < sizeof nonce; ++index)
        nonce[index] = (uint8_t)(0xA0 + index);

    uint8_t  ciphertext[256];
    uint32_t ciphertextLength = 0;
    if (BFAeadEncrypt(key, nonce, NULL, 0, (const uint8_t *)message, (uint32_t)strlen(message),
                      ciphertext, sizeof(ciphertext), &ciphertextLength) != 0) {
        fprintf(stderr, "encrypt failed\n");
        return 1;
    }
    uint8_t  plaintext[256];
    uint32_t plaintextLength = 0;
    if (BFAeadDecrypt(key, nonce, NULL, 0, ciphertext, ciphertextLength, plaintext,
                      sizeof(plaintext), &plaintextLength) != 0) {
        fprintf(stderr, "decrypt failed\n");
        return 1;
    }
    if (plaintextLength != strlen(message) || memcmp(plaintext, message, plaintextLength) != 0) {
        fprintf(stderr, "mismatch\n");
        return 1;
    }
    return 0;
#else
    // libsodium not linked; skip
    return 0;
#endif
}

