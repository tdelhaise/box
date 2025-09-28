//
//  ServerAdmin.c
//  boxd
//
//  Created by Thierry DELHAISE on 27/09/2025.
//

#include "BFCommon.h"
#include "BFMemory.h"
#include "BFRunloop.h"
#include "ServerAdmin.h"
#include "ServerEventType.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#if defined(__unix__) || defined(__APPLE__)
#include <pthread.h>
#endif
#include <pwd.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

#if defined(__unix__) || defined(__APPLE__)

void ServerAdminRequestDestroy(void *pointer) {
	if (!pointer) {
		return;
	}
	ServerAdminRequest *adminRequest = (ServerAdminRequest *)pointer;
	if (adminRequest->clientSocketDescriptor >= 0) {
		close(adminRequest->clientSocketDescriptor);
		adminRequest->clientSocketDescriptor = -1;
	}
	BFMemoryRelease(adminRequest);
}

BFResult ServerAdminWriteAll(int socketDescriptor, const char *buffer, size_t length) {
	size_t totalWritten = 0;
	while (totalWritten < length) {
		ssize_t written = write(socketDescriptor, buffer + totalWritten, length - totalWritten);
		if (written < 0) {
			if (errno == EINTR) {
				continue;
			}
			return BF_ERR;
		}
		if (written == 0) {
			return BF_ERR;
		}
		totalWritten += (size_t)written;
	}
	return BF_OK;
}

void *ServerAdminListenerThread(void *contextPointer) {
	ServerAdminThreadContext *threadContext = (ServerAdminThreadContext *)contextPointer;
	if (!threadContext) {
		return NULL;
	}
	const size_t bufferCapacity = sizeof(((ServerAdminRequest *)0)->requestBuffer);
	while (threadContext->runningFlagPointer && *(threadContext->runningFlagPointer)) {
		int clientSocketDescriptor = accept(threadContext->listenSocketDescriptor, NULL, NULL);
		if (clientSocketDescriptor < 0) {
			if (errno == EINTR) {
				continue;
			}
			if (!threadContext->runningFlagPointer || !*(threadContext->runningFlagPointer)) {
				break;
			}
			if (errno == EBADF) {
				break;
			}
			if (errno == EAGAIN || errno == EWOULDBLOCK) {
				continue;
			}
			BFWarn("boxd: admin accept failed (%d)", errno);
			continue;
		}
		
		int existingFlags = fcntl(clientSocketDescriptor, F_GETFL, 0);
		if (existingFlags >= 0) {
			(void)fcntl(clientSocketDescriptor, F_SETFL, existingFlags & ~O_NONBLOCK);
		}
		
		char   localRequestBuffer[sizeof(((ServerAdminRequest *)0)->requestBuffer)];
		size_t totalRead = 0;
		memset(localRequestBuffer, 0, sizeof(localRequestBuffer));
		while (totalRead < bufferCapacity - 1U) {
			ssize_t readCount = read(clientSocketDescriptor, localRequestBuffer + totalRead, (bufferCapacity - 1U) - totalRead);
			if (readCount < 0) {
				if (errno == EINTR) {
					continue;
				}
				break;
			}
			if (readCount == 0) {
				break;
			}
			totalRead += (size_t)readCount;
			if (memchr(localRequestBuffer, '\n', totalRead) != NULL) {
				break;
			}
		}
		
		if (totalRead == 0) {
			close(clientSocketDescriptor);
			continue;
		}
		if (totalRead >= bufferCapacity) {
			totalRead = bufferCapacity - 1U;
		}
		localRequestBuffer[totalRead] = '\0';
		
		ServerAdminRequest *adminRequest = (ServerAdminRequest *)BFMemoryAllocate(sizeof(ServerAdminRequest));
		if (!adminRequest) {
			BFWarn("boxd: unable to allocate admin request");
			close(clientSocketDescriptor);
			continue;
		}
		memset(adminRequest, 0, sizeof(ServerAdminRequest));
		adminRequest->clientSocketDescriptor = clientSocketDescriptor;
		adminRequest->requestLength          = totalRead;
		memcpy(adminRequest->requestBuffer, localRequestBuffer, totalRead + 1U);
		
		BFRunloopEvent adminEvent = {
			.type    = ServerEventAdminStatus,
			.payload = adminRequest,
			.destroy = ServerAdminRequestDestroy,
		};
		if (!threadContext->runloop || BFRunloopPost(threadContext->runloop, &adminEvent) != BF_OK) {
			ServerAdminRequestDestroy(adminRequest);
		}
	}
	return NULL;
}
#endif // __unix__ || __APPLE__
