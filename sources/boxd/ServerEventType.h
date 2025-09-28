//
//  ServerEventType.h
//  box
//
//  Created by Thierry DELHAISE on 27/09/2025.
//

#ifndef ServerEventType_h
#define ServerEventType_h

typedef enum ServerEventType {
    ServerEventTick = 1000,
    ServerEventAdminStatus = 1001,
    ServerEventNetworkInputStart = 1099,
    ServerEventNetworkDatagramInbound = 1100,
    ServerEventNoisePlaintext = 1101,
    ServerEventNetworkSocketReadable = 1102,
    ServerEventNetworkOutputSend = 1200
} ServerEventType;

#endif /* ServerEventType_h */
