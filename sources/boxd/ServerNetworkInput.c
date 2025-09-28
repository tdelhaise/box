//
//  ServerNetworkInput.c
//  boxd
//
//  Created by Thierry DELHAISE on 27/09/2025.
//

#include "BFRunloop.h"
#include "ServerNetworkInput.h"


void ServerNetworkInputHandler(BFRunloop *runloop, BFRunloopEvent *event, void *context) {
	(void)runloop;
	(void)context;
	if (event->type == BFRunloopEventStop)
		return;
}
