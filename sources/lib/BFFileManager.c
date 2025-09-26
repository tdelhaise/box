//
//  BFFileManager.c
//  BoxFoundation
//
//  Created by Thierry DELHAISE on 16/09/2025.
//

#include "BFFileManager.h"

#include "BFCommon.h"
#include "BFData.h"
#include "BFMemory.h"

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#if defined(_WIN32)
#include <direct.h>
#include <io.h>
#define BF_PATH_SEPARATOR '\\'
#define BF_ACCESS _access
#else
#include <unistd.h>
#define BF_PATH_SEPARATOR '/'
#define BF_ACCESS access
#endif

struct BFFileManager {
    char rootPath[PATH_MAX];
};

static int BFFileManagerJoinPath(const BFFileManager *fileManager, const char *relativePath, char *outPath, size_t outPathLength) {
    if (!fileManager || !outPath || outPathLength == 0U) {
        return BF_ERR;
    }

    if (!relativePath || *relativePath == '\0') {
        (void)snprintf(outPath, outPathLength, "%s", fileManager->rootPath);
        return BF_OK;
    }

    if (relativePath[0] == '/' || relativePath[0] == '\\') {
        return BF_ERR;
    }
    if (strstr(relativePath, "..")) {
        return BF_ERR;
    }

    if (fileManager->rootPath[0] == '\0') {
        (void)snprintf(outPath, outPathLength, "%s", relativePath ? relativePath : "");
    } else {
        size_t rootLength = strlen(fileManager->rootPath);
        int    needsSep   = (rootLength > 0 && fileManager->rootPath[rootLength - 1] != BF_PATH_SEPARATOR);
        (void)snprintf(outPath, outPathLength, "%s%s%s", fileManager->rootPath, needsSep ? (const char[]){BF_PATH_SEPARATOR, '\0'} : "", relativePath ? relativePath : "");
    }
#if defined(_WIN32)
    for (size_t i = 0; outPath[i] != '\0'; ++i) {
        if (outPath[i] == '/') {
            outPath[i] = BF_PATH_SEPARATOR;
        }
    }
#endif
    return BF_OK;
}

BFFileManager *BFFileManagerCreate(const char *rootPath) {
    BFFileManager *manager = (BFFileManager *)BFMemoryAllocate(sizeof(BFFileManager));
    if (!manager) {
        return NULL;
    }
    memset(manager, 0, sizeof(BFFileManager));
    if (rootPath && *rootPath) {
        size_t length = strlen(rootPath);
        if (length >= sizeof(manager->rootPath)) {
            BFMemoryRelease(manager);
            return NULL;
        }
        strcpy(manager->rootPath, rootPath);
#if defined(_WIN32)
        for (size_t i = 0; i < length; ++i) {
            if (manager->rootPath[i] == '/') {
                manager->rootPath[i] = BF_PATH_SEPARATOR;
            }
        }
#endif
    }
    // Ensure root directory exists
    (void)BFFileManagerEnsureDirectory(manager, "");
    return manager;
}

void BFFileManagerFree(BFFileManager *fileManager) {
    if (!fileManager) {
        return;
    }
    BFMemoryRelease(fileManager);
}

static int BFFileManagerCreateDirectory(const char *path) {
#if defined(_WIN32)
    if (_mkdir(path) == 0 || errno == EEXIST) {
        return BF_OK;
    }
#else
    if (mkdir(path, 0700) == 0 || errno == EEXIST) {
        return BF_OK;
    }
#endif
    return BF_ERR;
}

int BFFileManagerEnsureDirectory(BFFileManager *fileManager, const char *relativePath) {
    if (!fileManager) {
        return BF_ERR;
    }
    char fullPath[PATH_MAX];
    if (BFFileManagerJoinPath(fileManager, relativePath, fullPath, sizeof(fullPath)) != BF_OK) {
        return BF_ERR;
    }

    if (BF_ACCESS(fullPath, 0) == 0) {
        return BF_OK;
    }

    char pathBuffer[PATH_MAX];
    strncpy(pathBuffer, fullPath, sizeof(pathBuffer) - 1);
    pathBuffer[sizeof(pathBuffer) - 1] = '\0';

    char *p = pathBuffer;
    if (*p == '\0') {
        return BF_OK;
    }

    while (*p != '\0') {
        if (*p == '/' || *p == '\\') {
            char saved = *p;
            *p         = '\0';
            if (strlen(pathBuffer) > 0) {
                if (BFFileManagerCreateDirectory(pathBuffer) != BF_OK) {
                    *p = saved;
                    return BF_ERR;
                }
            }
            *p = saved;
        }
        ++p;
    }
    if (BFFileManagerCreateDirectory(pathBuffer) != BF_OK) {
        return BF_ERR;
    }
    return BF_OK;
}

int BFFileManagerWriteFile(BFFileManager *fileManager, const char *relativePath, const BFData *data) {
    if (!fileManager || !relativePath || !data) {
        return BF_ERR;
    }
    char fullPath[PATH_MAX];
    if (BFFileManagerJoinPath(fileManager, relativePath, fullPath, sizeof(fullPath)) != BF_OK) {
        return BF_ERR;
    }

    // Ensure parent directory exists
    char relativeCopy[PATH_MAX];
    strncpy(relativeCopy, relativePath, sizeof(relativeCopy) - 1);
    relativeCopy[sizeof(relativeCopy) - 1] = '\0';
#if defined(_WIN32)
    for (size_t i = 0; i < strlen(relativeCopy); ++i) {
        if (relativeCopy[i] == '\\') {
            relativeCopy[i] = '/';
        }
    }
#endif
    char *lastSlash = strrchr(relativeCopy, '/');
    if (lastSlash) {
        *lastSlash = '\0';
        if (BFFileManagerEnsureDirectory(fileManager, relativeCopy) != BF_OK) {
            return BF_ERR;
        }
    }

    char tempPath[PATH_MAX];
    snprintf(tempPath, sizeof(tempPath), "%s.tmp", fullPath);

    FILE *f = fopen(tempPath, "wb");
    if (!f) {
        return BF_ERR;
    }
    const uint8_t *bytes  = BFDataGetBytes(data);
    size_t         length = BFDataGetLength(data);
    if (length > 0 && bytes) {
        if (fwrite(bytes, 1U, length, f) != length) {
            fclose(f);
            (void)remove(tempPath);
            return BF_ERR;
        }
    }
    if (fclose(f) != 0) {
        (void)remove(tempPath);
        return BF_ERR;
    }
    if (rename(tempPath, fullPath) != 0) {
        (void)remove(tempPath);
        return BF_ERR;
    }
    return BF_OK;
}

int BFFileManagerReadFile(BFFileManager *fileManager, const char *relativePath, BFData *outData) {
    if (!fileManager || !relativePath || !outData) {
        return BF_ERR;
    }
    char fullPath[PATH_MAX];
    if (BFFileManagerJoinPath(fileManager, relativePath, fullPath, sizeof(fullPath)) != BF_OK) {
        return BF_ERR;
    }
    FILE *f = fopen(fullPath, "rb");
    if (!f) {
        return BF_ERR;
    }
    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        return BF_ERR;
    }
    long size = ftell(f);
    if (size < 0) {
        fclose(f);
        return BF_ERR;
    }
    if (fseek(f, 0, SEEK_SET) != 0) {
        fclose(f);
        return BF_ERR;
    }
    if (BFDataEnsureCapacity(outData, (size_t)size) != BF_OK) {
        fclose(f);
        return BF_ERR;
    }
    uint8_t *bytes = BFDataGetMutableBytes(outData);
    size_t   read  = (size_t)size;
    if (read > 0 && bytes) {
        if (fread(bytes, 1U, read, f) != read) {
            fclose(f);
            return BF_ERR;
        }
    }
    (void)BFDataSetLength(outData, (size_t)size);
    fclose(f);
    return BF_OK;
}

int BFFileManagerRemoveFile(BFFileManager *fileManager, const char *relativePath) {
    if (!fileManager || !relativePath) {
        return BF_ERR;
    }
    char fullPath[PATH_MAX];
    if (BFFileManagerJoinPath(fileManager, relativePath, fullPath, sizeof(fullPath)) != BF_OK) {
        return BF_ERR;
    }
    if (remove(fullPath) != 0) {
        return BF_ERR;
    }
    return BF_OK;
}
