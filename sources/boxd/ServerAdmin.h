//
//  ServerAdmin.h
//  boxd
//
//  Created by Thierry DELHAISE on 27/09/2025.
//

#ifndef ServerAdmin_h
#define ServerAdmin_h

#include <stdio.h>

#if defined(__unix__) || defined(__APPLE__)
typedef struct ServerAdminRequest {
	int    clientSocketDescriptor;
	size_t requestLength;
	char   requestBuffer[128];
} ServerAdminRequest;

typedef struct ServerAdminThreadContext {
	int           listenSocketDescriptor;
	BFRunloop    *runloop;
	volatile int *runningFlagPointer;
} ServerAdminThreadContext;

void ServerAdminRequestDestroy(void *pointer);
int ServerAdminWriteAll(int socketDescriptor, const char *buffer, size_t length);
void *ServerAdminListenerThread(void *contextPointer);

#endif

#endif /* ServerAdmin_h */
