#ifndef BF_STORAGE_MANAGER_H
#define BF_STORAGE_MANAGER_H

#include "BFData.h"
#include "BFFileManager.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BFStorageManager BFStorageManager;

typedef enum {
    BFStorageManagerGetLast,
    BFStorageManagerGetById
} BFStorageManagerGetMode;

BFStorageManager *BFStorageManagerCreate(BFFileManager *fileManager);

void BFStorageManagerFree(BFStorageManager *storageManager);

int BFStorageManagerPut(BFStorageManager *storageManager, const char *queueName, const BFData *payload, char *outMessageId, size_t outMessageIdLength);

int BFStorageManagerGet(BFStorageManager *storageManager, const char *queueName, BFStorageManagerGetMode mode, const char *messageId, BFData *outPayload, char *outResolvedMessageId, size_t outResolvedMessageIdLength);

int BFStorageManagerDelete(BFStorageManager *storageManager, const char *queueName, const char *messageId);

#ifdef __cplusplus
}
#endif

#endif
