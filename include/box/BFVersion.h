#ifndef BF_VERSION_H
#define BF_VERSION_H

#ifdef __cplusplus
extern "C" {
#endif

// Returns the project version string (semver-like), e.g., "0.1.0".
const char *BFVersionString(void);

#ifdef __cplusplus
}
#endif

#endif // BF_VERSION_H

