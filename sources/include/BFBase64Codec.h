// BFBase64Codec — conversions between BFString and BFData using Base64.

#ifndef BF_BASE64_CODEC_H
#define BF_BASE64_CODEC_H

#include "BFString.h"

#ifdef __cplusplus
extern "C" {
#endif

int BFBase64CodecEncodeDataToString(const BFData *data, BFString *outString);
int BFBase64CodecEncodeStringToString(const BFString *plainString, BFString *outString);
int BFBase64CodecDecodeStringToData(const BFString *encodedString, BFData *outData);
int BFBase64CodecDecodeStringToString(const BFString *encodedString, BFString *outString);

#ifdef __cplusplus
}
#endif

#endif // BF_BASE64_CODEC_H
