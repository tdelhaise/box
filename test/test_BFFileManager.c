#include "BFCommon.h"
#include "BFData.h"
#include "BFFileManager.h"
#include "BFMemory.h"

#include <assert.h>
#include <limits.h>
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

static void testFileManagerBasic(void) {
#if defined(_WIN32)
    char tempDirectory[MAX_PATH];
    char rootPathBuffer[MAX_PATH];
    DWORD tempLength = GetTempPathA(MAX_PATH, tempDirectory);
    assert(tempLength > 0);
    UINT uniqueResult = GetTempFileNameA(tempDirectory, "bft", 0, rootPathBuffer);
    assert(uniqueResult != 0);
    DeleteFileA(rootPathBuffer);
    CreateDirectoryA(rootPathBuffer, NULL);
    const char *rootPath = rootPathBuffer;
#else
    char rootTemplate[] = "/tmp/bf_storage_XXXXXX";
    char *rootGenerated = mkdtemp(rootTemplate);
    assert(rootGenerated != NULL);
    const char *rootPath = rootGenerated;
#endif

    BFFileManager *manager = BFFileManagerCreate(rootPath);
#if defined(_WIN32)
    assert(manager != NULL);
#else
    assert(manager != NULL);
#endif

    assert(BFFileManagerEnsureDirectory(manager, "queues/queue1") == BF_OK);

    const char  *relativeFile = "queues/queue1/test.msg";
    const char  *payloadText  = "bonjour";
    BFData       payload      = BFDataCreateWithBytes((const uint8_t *)payloadText, strlen(payloadText));
    assert(BFFileManagerWriteFile(manager, relativeFile, &payload) == BF_OK);

    BFData readBack = BFDataCreate(0U);
    assert(BFFileManagerReadFile(manager, relativeFile, &readBack) == BF_OK);
    assert(BFDataGetLength(&readBack) == strlen(payloadText));
    assert(memcmp(BFDataGetBytes(&readBack), payloadText, strlen(payloadText)) == 0);

    assert(BFFileManagerRemoveFile(manager, relativeFile) == BF_OK);
    assert(BFFileManagerReadFile(manager, relativeFile, &readBack) == BF_ERR);

    BFDataReset(&payload);
    BFDataReset(&readBack);
    BFFileManagerFree(manager);

#if defined(_WIN32)
    removeDirectoryRecursive(rootPathBuffer);
#else
    removeDirectoryRecursive(rootPath);
#endif
}

int main(void) {
    testFileManagerBasic();
    printf("BFFileManager tests OK\n");
    return 0;
}
