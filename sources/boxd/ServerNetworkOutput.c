//
//  ServerNetworkOutput.c
//  boxd
//
//  Created by Thierry DELHAISE on 27/09/2025.
//

#include "BFRunloop.h"
#include "ServerNetworkOutput.h"


void ServerNetworkOutputHandler(BFRunloop *runloop, BFRunloopEvent *event, void *context) {
	(void)runloop;
	(void)context;
	if (event->type == BFRunloopEventStop)
		return;
}
