// BFRunloop — lightweight single-consumer event loop with a bounded serial queue
// Thread-safe posting; single handler invoked on the run loop thread.

#ifndef BF_RUNLOOP_H
#define BF_RUNLOOP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BFRunloop BFRunloop;

typedef enum BFRunloopEventType {
    BFRunloopEventStop = 1,
} BFRunloopEventType;

typedef enum BFRunloopFdMode {
    BFRunloopFdModeRead  = 1U << 0,
    BFRunloopFdModeWrite = 1U << 1,
} BFRunloopFdMode;

typedef struct BFRunloopEvent {
    uint32_t type;
    void    *payload;               // owned by the run loop
    void (*destroy)(void *pointer); // optional; called after handling or on drop
} BFRunloopEvent;

typedef void (*BFRunloopHandler)(BFRunloop *runloop, BFRunloopEvent *event, void *context);

// Lifecycle
BFRunloop *BFRunloopCreate(void);
void       BFRunloopFree(BFRunloop *runloop);

// Handler and execution
int  BFRunloopSetHandler(BFRunloop *runloop, BFRunloopHandler handler, void *context);
int  BFRunloopStart(BFRunloop *runloop); // spawns a thread to run the loop
void BFRunloopRun(BFRunloop *runloop);   // runs the loop on the caller thread (blocking)
void BFRunloopJoin(BFRunloop *runloop);  // joins the internal thread if started

// Queue operations
int  BFRunloopPost(BFRunloop *runloop, const BFRunloopEvent *event); // returns BF_OK or BF_ERR
void BFRunloopPostStop(BFRunloop *runloop);                          // posts a stop marker (guaranteed enqueue)

// Stop the runloop; if drain is non-zero, the loop drains queued events before stopping (default).
void BFRunloopStop(BFRunloop *runloop, int drain);

// Reactor integration (platform-specific backends).
int BFRunloopAddFileDescriptor(BFRunloop *runloop,
                               int        fileDescriptor,
                               uint32_t   modes,
                               const BFRunloopEvent *templateEvent);
int BFRunloopRemoveFileDescriptor(BFRunloop *runloop, int fileDescriptor);

#ifdef __cplusplus
}
#endif

#endif // BF_RUNLOOP_H
