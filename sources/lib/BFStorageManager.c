#include "BFStorageManager.h"

#include "BFCommon.h"
#include "BFData.h"
#include "BFFileManager.h"
#include "BFMemory.h"

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct BFStorageManager {
    BFFileManager *fileManager;
};

static int BFStorageManagerQueuePath(char *buffer, size_t bufferLength, const char *queueName) {
    if (!queueName || !*queueName) {
        return BF_ERR;
    }
    for (const char *p = queueName; *p; ++p) {
        if (*p == '/' || *p == '\\') {
            return BF_ERR;
        }
    }
    (void)snprintf(buffer, bufferLength, "queues/%s", queueName);
    return BF_OK;
}

static void BFStorageManagerGenerateMessageId(char *buffer, size_t bufferLength) {
    time_t now = time(NULL);
    unsigned int randomValue = (unsigned int)rand();
    (void)snprintf(buffer, bufferLength, "%lld-%u", (long long)now, randomValue);
}

BFStorageManager *BFStorageManagerCreate(BFFileManager *fileManager) {
    if (!fileManager) {
        return NULL;
    }
    static int seeded = 0;
    if (!seeded) {
        seeded = 1;
        srand((unsigned int)time(NULL));
    }
    BFStorageManager *storageManager = (BFStorageManager *)BFMemoryAllocate(sizeof(BFStorageManager));
    if (!storageManager) {
        return NULL;
    }
    memset(storageManager, 0, sizeof(BFStorageManager));
    storageManager->fileManager = fileManager;
    return storageManager;
}

void BFStorageManagerFree(BFStorageManager *storageManager) {
    if (!storageManager) {
        return;
    }
    BFMemoryRelease(storageManager);
}

int BFStorageManagerPut(BFStorageManager *storageManager, const char *queueName, const BFData *payload, char *outMessageId, size_t outMessageIdLength) {
    if (!storageManager || !queueName || !payload) {
        return BF_ERR;
    }
    char queuePath[256];
    if (BFStorageManagerQueuePath(queuePath, sizeof(queuePath), queueName) != BF_OK) {
        return BF_ERR;
    }
    if (BFFileManagerEnsureDirectory(storageManager->fileManager, queuePath) != BF_OK) {
        return BF_ERR;
    }
    char messageIdBuffer[64];
    BFStorageManagerGenerateMessageId(messageIdBuffer, sizeof(messageIdBuffer));

    char filePath[512];
    (void)snprintf(filePath, sizeof(filePath), "%s/%s.msg", queuePath, messageIdBuffer);
    if (BFFileManagerWriteFile(storageManager->fileManager, filePath, payload) != BF_OK) {
        return BF_ERR;
    }

    char pointerPath[512];
    (void)snprintf(pointerPath, sizeof(pointerPath), "%s/latest.id", queuePath);
    BFData pointerData = BFDataCreateWithBytes((const uint8_t *)messageIdBuffer, strlen(messageIdBuffer));
    if (BFFileManagerWriteFile(storageManager->fileManager, pointerPath, &pointerData) != BF_OK) {
        BFDataReset(&pointerData);
        return BF_ERR;
    }
    BFDataReset(&pointerData);

    if (outMessageId && outMessageIdLength > 0) {
        (void)snprintf(outMessageId, outMessageIdLength, "%s", messageIdBuffer);
    }
    return BF_OK;
}

int BFStorageManagerGet(BFStorageManager *storageManager, const char *queueName, BFStorageManagerGetMode mode, const char *messageId, BFData *outPayload, char *outResolvedMessageId, size_t outResolvedMessageIdLength) {
    if (!storageManager || !queueName || !outPayload) {
        return BF_ERR;
    }
    char queuePath[256];
    if (BFStorageManagerQueuePath(queuePath, sizeof(queuePath), queueName) != BF_OK) {
        return BF_ERR;
    }
    if (BFFileManagerEnsureDirectory(storageManager->fileManager, queuePath) != BF_OK) {
        return BF_ERR;
    }

    char targetFile[512];
    if (mode == BFStorageManagerGetById) {
        if (!messageId || !*messageId) {
            return BF_ERR;
        }
        (void)snprintf(targetFile, sizeof(targetFile), "%s/%s.msg", queuePath, messageId);
        if (BFFileManagerReadFile(storageManager->fileManager, targetFile, outPayload) != BF_OK) {
            return BF_ERR;
        }
        if (outResolvedMessageId && outResolvedMessageIdLength > 0) {
            (void)snprintf(outResolvedMessageId, outResolvedMessageIdLength, "%s", messageId);
        }
        return BF_OK;
    }

    char pointerPath[512];
    (void)snprintf(pointerPath, sizeof(pointerPath), "%s/latest.id", queuePath);
    BFData idData = BFDataCreate(0U);
    if (BFFileManagerReadFile(storageManager->fileManager, pointerPath, &idData) != BF_OK) {
        BFDataReset(&idData);
        return BF_ERR;
    }
    char resolvedId[128];
    size_t idLength = BFDataGetLength(&idData);
    if (idLength >= sizeof(resolvedId)) {
        BFDataReset(&idData);
        return BF_ERR;
    }
    memcpy(resolvedId, BFDataGetBytes(&idData), idLength);
    resolvedId[idLength] = '\0';
    BFDataReset(&idData);

    (void)snprintf(targetFile, sizeof(targetFile), "%s/%s.msg", queuePath, resolvedId);
    if (BFFileManagerReadFile(storageManager->fileManager, targetFile, outPayload) != BF_OK) {
        return BF_ERR;
    }
    if (outResolvedMessageId && outResolvedMessageIdLength > 0) {
        snprintf(outResolvedMessageId, outResolvedMessageIdLength, "%s", resolvedId);
    }
    return BF_OK;
}

int BFStorageManagerDelete(BFStorageManager *storageManager, const char *queueName, const char *messageId) {
    if (!storageManager || !queueName || !messageId) {
        return BF_ERR;
    }
    char queuePath[256];
    if (BFStorageManagerQueuePath(queuePath, sizeof(queuePath), queueName) != BF_OK) {
        return BF_ERR;
    }
    char targetFile[512];
    (void)snprintf(targetFile, sizeof(targetFile), "%s/%s.msg", queuePath, messageId);
    return BFFileManagerRemoveFile(storageManager->fileManager, targetFile);
}
