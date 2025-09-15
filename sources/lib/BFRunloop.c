#include "BFRunloop.h"
#include "BFCommon.h"
#include "BFMemory.h"

#include <pthread.h>
#include <string.h>

enum { BFRunloopMaxEvents = 512 };

typedef struct BFRunloopQueue {
    BFRunloopEvent events[BFRunloopMaxEvents];
    size_t         head;  // index of next pop
    size_t         tail;  // index of next push
    size_t         count; // number of items in queue
} BFRunloopQueue;

struct BFRunloop {
    pthread_mutex_t  mutex;
    pthread_cond_t   condition;
    BFRunloopQueue   queue;
    int              stopping; // 0 running, 1 stop requested (drain), 2 immediate stop
    int              started;
    pthread_t        thread;
    BFRunloopHandler handler;
    void            *handlerContext;
};

static void QueueInit(BFRunloopQueue *q) {
    memset(q, 0, sizeof(*q));
}

static int QueuePush(BFRunloopQueue *q, const BFRunloopEvent *ev) {
    if (q->count >= BFRunloopMaxEvents) {
        return BF_ERR;
    }
    q->events[q->tail] = *ev;
    q->tail            = (q->tail + 1U) % BFRunloopMaxEvents;
    q->count++;
    return BF_OK;
}

static int QueuePushForce(BFRunloopQueue *q, const BFRunloopEvent *ev) {
    // Used for STOP event to guarantee enqueue; drop oldest if necessary
    if (q->count >= BFRunloopMaxEvents) {
        // drop oldest
        BFRunloopEvent *old = &q->events[q->head];
        if (old->destroy != NULL && old->payload != NULL) {
            old->destroy(old->payload);
        }
        q->head = (q->head + 1U) % BFRunloopMaxEvents;
        q->count--;
    }
    return QueuePush(q, ev);
}

static int QueuePop(BFRunloopQueue *q, BFRunloopEvent *out) {
    if (q->count == 0U) {
        return BF_ERR;
    }
    *out    = q->events[q->head];
    q->head = (q->head + 1U) % BFRunloopMaxEvents;
    q->count--;
    return BF_OK;
}

static void *RunloopThreadMain(void *arg) {
    BFRunloop *runloop = (BFRunloop *)arg;
    BFRunloopRun(runloop);
    return NULL;
}

BFRunloop *BFRunloopCreate(void) {
    BFRunloop *rl = (BFRunloop *)BFMemoryAllocate(sizeof(BFRunloop));
    if (rl == NULL) {
        return NULL;
    }
    memset(rl, 0, sizeof(*rl));
    pthread_mutex_init(&rl->mutex, NULL);
    pthread_cond_init(&rl->condition, NULL);
    QueueInit(&rl->queue);
    rl->stopping       = 0;
    rl->started        = 0;
    rl->handler        = NULL;
    rl->handlerContext = NULL;
    return rl;
}

void BFRunloopFree(BFRunloop *runloop) {
    if (runloop == NULL) {
        return;
    }
    // Drain and destroy any remaining events
    pthread_mutex_lock(&runloop->mutex);
    BFRunloopEvent ev;
    while (QueuePop(&runloop->queue, &ev) == BF_OK) {
        if (ev.destroy != NULL && ev.payload != NULL) {
            ev.destroy(ev.payload);
        }
    }
    pthread_mutex_unlock(&runloop->mutex);

    pthread_mutex_destroy(&runloop->mutex);
    pthread_cond_destroy(&runloop->condition);
    BFMemoryRelease(runloop);
}

int BFRunloopSetHandler(BFRunloop *runloop, BFRunloopHandler handler, void *context) {
    if (runloop == NULL || handler == NULL) {
        return BF_ERR;
    }
    pthread_mutex_lock(&runloop->mutex);
    runloop->handler        = handler;
    runloop->handlerContext = context;
    pthread_mutex_unlock(&runloop->mutex);
    return BF_OK;
}

int BFRunloopStart(BFRunloop *runloop) {
    if (runloop == NULL) {
        return BF_ERR;
    }
    pthread_mutex_lock(&runloop->mutex);
    if (runloop->started != 0) {
        pthread_mutex_unlock(&runloop->mutex);
        return BF_ERR;
    }
    runloop->started = 1;
    pthread_mutex_unlock(&runloop->mutex);
    if (pthread_create(&runloop->thread, NULL, RunloopThreadMain, runloop) != 0) {
        pthread_mutex_lock(&runloop->mutex);
        runloop->started = 0;
        pthread_mutex_unlock(&runloop->mutex);
        return BF_ERR;
    }
    return BF_OK;
}

void BFRunloopRun(BFRunloop *runloop) {
    if (runloop == NULL) {
        return;
    }
    for (;;) {
        pthread_mutex_lock(&runloop->mutex);
        while (runloop->queue.count == 0U && runloop->stopping == 0) {
            pthread_cond_wait(&runloop->condition, &runloop->mutex);
        }

        BFRunloopEvent event;
        int            have = QueuePop(&runloop->queue, &event);

        // If stopping was requested and queue is empty, exit
        if (have != BF_OK && runloop->stopping != 0) {
            pthread_mutex_unlock(&runloop->mutex);
            break;
        }

        pthread_mutex_unlock(&runloop->mutex);

        if (have != BF_OK) {
            continue; // spurious wakeup
        }

        if (event.type == BFRunloopEventStop) {
            // Switch to stopping state and continue draining remaining events
            pthread_mutex_lock(&runloop->mutex);
            runloop->stopping = 1;
            int empty         = (runloop->queue.count == 0U);
            pthread_mutex_unlock(&runloop->mutex);
            if (event.destroy != NULL && event.payload != NULL) {
                event.destroy(event.payload);
            }
            if (empty != 0) {
                break; // nothing else to drain
            }
            continue;
        }

        if (runloop->handler != NULL) {
            runloop->handler(runloop, &event, runloop->handlerContext);
        }

        if (event.destroy != NULL && event.payload != NULL) {
            event.destroy(event.payload);
        }
    }
}

void BFRunloopJoin(BFRunloop *runloop) {
    if (runloop == NULL) {
        return;
    }
    pthread_mutex_lock(&runloop->mutex);
    int started = runloop->started;
    pthread_mutex_unlock(&runloop->mutex);
    if (started != 0) {
        (void)pthread_join(runloop->thread, NULL);
        pthread_mutex_lock(&runloop->mutex);
        runloop->started = 0;
        pthread_mutex_unlock(&runloop->mutex);
    }
}

int BFRunloopPost(BFRunloop *runloop, const BFRunloopEvent *event) {
    if (runloop == NULL || event == NULL) {
        return BF_ERR;
    }
    pthread_mutex_lock(&runloop->mutex);
    if (runloop->stopping != 0) {
        pthread_mutex_unlock(&runloop->mutex);
        return BF_ERR;
    }
    int ok = QueuePush(&runloop->queue, event);
    if (ok == BF_OK) {
        pthread_cond_signal(&runloop->condition);
    }
    pthread_mutex_unlock(&runloop->mutex);
    return ok;
}

void BFRunloopPostStop(BFRunloop *runloop) {
    if (runloop == NULL) {
        return;
    }
    BFRunloopEvent stopEvent;
    memset(&stopEvent, 0, sizeof(stopEvent));
    stopEvent.type    = BFRunloopEventStop;
    stopEvent.payload = NULL;
    stopEvent.destroy = NULL;

    pthread_mutex_lock(&runloop->mutex);
    (void)QueuePushForce(&runloop->queue, &stopEvent);
    pthread_cond_signal(&runloop->condition);
    pthread_mutex_unlock(&runloop->mutex);
}

void BFRunloopStop(BFRunloop *runloop, int drain) {
    if (runloop == NULL) {
        return;
    }
    if (drain == 0) {
        pthread_mutex_lock(&runloop->mutex);
        runloop->stopping = 2;
        // Clear queue immediately (destroy payloads)
        BFRunloopEvent ev;
        while (QueuePop(&runloop->queue, &ev) == BF_OK) {
            if (ev.destroy != NULL && ev.payload != NULL) {
                ev.destroy(ev.payload);
            }
        }
        pthread_cond_signal(&runloop->condition);
        pthread_mutex_unlock(&runloop->mutex);
    } else {
        BFRunloopPostStop(runloop);
    }
}
