#ifndef BF_AEAD_H
#define BF_AEAD_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// AEAD helpers (XChaCha20-Poly1305, libsodium-backed)

// Constants (fallback to typical sizes if libsodium headers are not available at build time)
#if defined(HAVE_SODIUM)
#include <sodium.h>
enum {
    BF_AEAD_KEY_BYTES   = crypto_aead_xchacha20poly1305_ietf_KEYBYTES,
    BF_AEAD_NONCE_BYTES = crypto_aead_xchacha20poly1305_ietf_NPUBBYTES,
    BF_AEAD_ABYTES      = crypto_aead_xchacha20poly1305_ietf_ABYTES,
};
#else
enum {
    BF_AEAD_KEY_BYTES   = 32,
    BF_AEAD_NONCE_BYTES = 24,
    BF_AEAD_ABYTES      = 16,
};
#endif

// Encrypts plaintext into ciphertext using XChaCha20-Poly1305 (ietf variant).
// - key: 32 bytes
// - nonce: 24 bytes (XChaCha)
// - associatedData may be NULL when associatedDataLength is 0
// Returns BF_OK on success and sets *outCiphertextLength; BF_ERR on failure.
int BFAeadEncrypt(const uint8_t *key,
                  const uint8_t *nonce,
                  const uint8_t *associatedData,
                  uint32_t       associatedDataLength,
                  const uint8_t *plaintext,
                  uint32_t       plaintextLength,
                  uint8_t       *ciphertext,
                  uint32_t       ciphertextBufferLength,
                  uint32_t      *outCiphertextLength);

// Decrypts ciphertext into plaintext using XChaCha20-Poly1305 (ietf variant).
// Returns BF_OK on success and sets *outPlaintextLength; BF_ERR on failure (e.g., MAC failure).
int BFAeadDecrypt(const uint8_t *key,
                  const uint8_t *nonce,
                  const uint8_t *associatedData,
                  uint32_t       associatedDataLength,
                  const uint8_t *ciphertext,
                  uint32_t       ciphertextLength,
                  uint8_t       *plaintext,
                  uint32_t       plaintextBufferLength,
                  uint32_t      *outPlaintextLength);

#ifdef __cplusplus
}
#endif

#endif // BF_AEAD_H

