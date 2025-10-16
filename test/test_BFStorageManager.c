#include "BFCommon.h"
#include "BFData.h"
#include "BFFileManager.h"
#include "BFMemory.h"
#include "BFStorageManager.h"

#include <assert.h>
#include <limits.h>
#ifndef PATH_MAX
#define PATH_MAX 4096
#endif
#include <stdio.h>
#include <string.h>

#if defined(_WIN32)
#include <direct.h>
#include <windows.h>
#else
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

static void removeDirectoryRecursive(const char *path) {
#if defined(_WIN32)
    WIN32_FIND_DATAA findData;
    char             searchPath[MAX_PATH];
    snprintf(searchPath, sizeof(searchPath), "%s\\*", path);
    HANDLE handle = FindFirstFileA(searchPath, &findData);
    if (handle == INVALID_HANDLE_VALUE) {
        RemoveDirectoryA(path);
        return;
    }
    do {
        if (strcmp(findData.cFileName, ".") == 0 || strcmp(findData.cFileName, "..") == 0) {
            continue;
        }
        char childPath[MAX_PATH];
        snprintf(childPath, sizeof(childPath), "%s\\%s", path, findData.cFileName);
        if (findData.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            removeDirectoryRecursive(childPath);
        } else {
            DeleteFileA(childPath);
        }
    } while (FindNextFileA(handle, &findData));
    FindClose(handle);
    RemoveDirectoryA(path);
#else
    DIR *dir = opendir(path);
    if (!dir) {
        (void)unlink(path);
        return;
    }
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        char childPath[PATH_MAX];
        snprintf(childPath, sizeof(childPath), "%s/%s", path, entry->d_name);
        struct stat st;
        if (stat(childPath, &st) == 0 && S_ISDIR(st.st_mode)) {
            removeDirectoryRecursive(childPath);
        } else {
            (void)unlink(childPath);
        }
    }
    closedir(dir);
    (void)rmdir(path);
#endif
}

static void makeTempRoot(char *outPath, size_t outLength) {
#if defined(_WIN32)
    char tempDirectory[MAX_PATH];
    DWORD tempLength = GetTempPathA(MAX_PATH, tempDirectory);
    assert(tempLength > 0);
    UINT uniqueResult = GetTempFileNameA(tempDirectory, "bst", 0, outPath);
    assert(uniqueResult != 0);
    DeleteFileA(outPath);
    CreateDirectoryA(outPath, NULL);
#else
    char template[] = "/tmp/bf_storage_mgr_XXXXXX";
    char *result    = mkdtemp(template);
    assert(result != NULL);
    snprintf(outPath, outLength, "%s", result);
#endif
}

static void testStoragePutGet(void) {
    char rootPathBuffer[PATH_MAX];
    makeTempRoot(rootPathBuffer, sizeof(rootPathBuffer));

    BFFileManager    *fileManager    = BFFileManagerCreate(rootPathBuffer);
    BFStorageManager *storageManager = BFStorageManagerCreate(fileManager);

    BFData payload = BFDataCreateWithBytes((const uint8_t *)"contenu", strlen("contenu"));
    char   messageId[128];
    assert(BFStorageManagerPut(storageManager, "queue1", &payload, messageId, sizeof(messageId)) == BF_OK);
    assert(strlen(messageId) > 0);

    BFData retrieved = BFDataCreate(0U);
    char   resolvedId[128];
    assert(BFStorageManagerGet(storageManager, "queue1", BFStorageManagerGetLast, NULL, &retrieved, resolvedId, sizeof(resolvedId)) == BF_OK);
    assert(strcmp(resolvedId, messageId) == 0);
    assert(BFDataGetLength(&retrieved) == strlen("contenu"));
    assert(memcmp(BFDataGetBytes(&retrieved), "contenu", strlen("contenu")) == 0);

    BFDataReset(&retrieved);
    assert(BFStorageManagerGet(storageManager, "queue1", BFStorageManagerGetById, messageId, &retrieved, NULL, 0) == BF_OK);
    assert(BFDataGetLength(&retrieved) == strlen("contenu"));

    assert(BFStorageManagerDelete(storageManager, "queue1", messageId) == BF_OK);
    BFDataReset(&retrieved);
    assert(BFStorageManagerGet(storageManager, "queue1", BFStorageManagerGetById, messageId, &retrieved, NULL, 0) == BF_ERR);

    BFDataReset(&payload);
    BFDataReset(&retrieved);
    BFStorageManagerFree(storageManager);
    BFFileManagerFree(fileManager);
    removeDirectoryRecursive(rootPathBuffer);
}

int main(void) {
    testStoragePutGet();
    printf("BFStorageManager tests OK\n");
    return 0;
}
