//
//  BFFileManager.h
//  box
//
//  Created by Thierry DELHAISE on 16/09/2025.
//

#ifndef BF_FILE_MANAGER_H
#define BF_FILE_MANAGER_H

#include "BFData.h"
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BFFileManager BFFileManager;

BFFileManager *BFFileManagerCreate(const char *rootPath);

void BFFileManagerFree(BFFileManager *fileManager);

int BFFileManagerEnsureDirectory(BFFileManager *fileManager, const char *relativePath);

int BFFileManagerWriteFile(BFFileManager *fileManager, const char *relativePath, const BFData *data);

int BFFileManagerReadFile(BFFileManager *fileManager, const char *relativePath, BFData *outData);

int BFFileManagerRemoveFile(BFFileManager *fileManager, const char *relativePath);

#ifdef __cplusplus
}
#endif

#endif // !BF_FILE_MANAGER_H
