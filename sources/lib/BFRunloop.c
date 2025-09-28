#include "BFRunloop.h"

#include "BFCommon.h"
#include "BFMemory.h"

#include <errno.h>
#include <pthread.h>
#include <string.h>

#if defined(_WIN32)
#include <io.h>
#include <windows.h>
#else
#include <unistd.h>
#include <fcntl.h>
#endif

#if defined(__APPLE__) || defined(__FreeBSD__)
#include <sys/event.h>
#include <sys/time.h>
#elif defined(__linux__)
#include <sys/epoll.h>
#include <sys/eventfd.h>
#endif

enum { BFRunloopMaxEvents = 512 };

typedef struct BFRunloopQueue {
    BFRunloopEvent events[BFRunloopMaxEvents];
    size_t         head;
    size_t         tail;
    size_t         count;
} BFRunloopQueue;

typedef struct BFRunloopFdSource {
    int                      fileDescriptor;
    uint32_t                 modes;
    BFRunloopEvent           eventTemplate;
    struct BFRunloopFdSource *next;
} BFRunloopFdSource;

typedef enum BFRunloopBackendType {
    BFRunloopBackendNone = 0,
    BFRunloopBackendKqueue,
    BFRunloopBackendEpoll,
} BFRunloopBackendType;

struct BFRunloop {
    pthread_mutex_t  mutex;
    pthread_cond_t   condition;
    BFRunloopQueue   queue;
    int              stopping; // 0 running, 1 stop requested (drain), 2 immediate stop
    int              started;
    pthread_t        thread;
    BFRunloopHandler handler;
    void            *handlerContext;

    BFRunloopBackendType backendType;
    int                  backendFd;
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__linux__)
    int wakeupReadFd;
    int wakeupWriteFd;
#endif
    BFRunloopFdSource *fdSources;
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
    if (q->count >= BFRunloopMaxEvents) {
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

#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__linux__)
static int makeNonBlocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) {
        return BF_ERR;
    }
    if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        return BF_ERR;
    }
    return BF_OK;
}
#endif

#if defined(__APPLE__) || defined(__FreeBSD__)
static int BackendInit(BFRunloop *runloop) {
    runloop->backendFd = kqueue();
    if (runloop->backendFd < 0) {
        return BF_ERR;
    }
    int pipeFds[2];
    if (pipe(pipeFds) != 0) {
        close(runloop->backendFd);
        runloop->backendFd = -1;
        return BF_ERR;
    }
    runloop->wakeupReadFd  = pipeFds[0];
    runloop->wakeupWriteFd = pipeFds[1];
    (void)makeNonBlocking(runloop->wakeupReadFd);
    struct kevent kev;
    EV_SET(&kev, (uintptr_t)runloop->wakeupReadFd, EVFILT_READ, EV_ADD | EV_CLEAR, 0, 0, NULL);
    if (kevent(runloop->backendFd, &kev, 1, NULL, 0, NULL) != 0) {
        close(runloop->backendFd);
        close(runloop->wakeupReadFd);
        close(runloop->wakeupWriteFd);
        runloop->backendFd      = -1;
        runloop->wakeupReadFd   = -1;
        runloop->wakeupWriteFd  = -1;
        return BF_ERR;
    }
    runloop->backendType = BFRunloopBackendKqueue;
    return BF_OK;
}
#elif defined(__linux__)
static int BackendInit(BFRunloop *runloop) {
    runloop->backendFd = epoll_create1(EPOLL_CLOEXEC);
    if (runloop->backendFd < 0) {
        return BF_ERR;
    }
    int eventFd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (eventFd < 0) {
        close(runloop->backendFd);
        runloop->backendFd = -1;
        return BF_ERR;
    }
    runloop->wakeupReadFd  = eventFd;
    runloop->wakeupWriteFd = eventFd;
    struct epoll_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.events  = EPOLLIN;
    ev.data.ptr = NULL;
    if (epoll_ctl(runloop->backendFd, EPOLL_CTL_ADD, eventFd, &ev) != 0) {
        close(eventFd);
        close(runloop->backendFd);
        runloop->backendFd      = -1;
        runloop->wakeupReadFd   = -1;
        runloop->wakeupWriteFd  = -1;
        return BF_ERR;
    }
    runloop->backendType = BFRunloopBackendEpoll;
    return BF_OK;
}
#else
static int BackendInit(BFRunloop *runloop) {
    (void)runloop;
    return BF_ERR;
}
#endif

#if defined(__APPLE__) || defined(__FreeBSD__)
static void BackendSignal(BFRunloop *runloop) {
    if (runloop->backendType == BFRunloopBackendKqueue && runloop->wakeupWriteFd >= 0) {
        uint8_t byte = 1;
        (void)write(runloop->wakeupWriteFd, &byte, sizeof(byte));
    }
}

static void BackendDrain(BFRunloop *runloop) {
    if (runloop->backendType == BFRunloopBackendKqueue && runloop->wakeupReadFd >= 0) {
        uint8_t buffer[32];
        while (read(runloop->wakeupReadFd, buffer, sizeof(buffer)) > 0) {
        }
    }
}
#elif defined(__linux__)
static void BackendSignal(BFRunloop *runloop) {
    if (runloop->backendType == BFRunloopBackendEpoll && runloop->wakeupWriteFd >= 0) {
        uint64_t value = 1ULL;
        (void)write(runloop->wakeupWriteFd, &value, sizeof(value));
    }
}

static void BackendDrain(BFRunloop *runloop) {
    if (runloop->backendType == BFRunloopBackendEpoll && runloop->wakeupReadFd >= 0) {
        uint64_t value;
        while (read(runloop->wakeupReadFd, &value, sizeof(value)) > 0) {
        }
    }
}
#else
static void BackendSignal(BFRunloop *runloop) {
    (void)runloop;
}

static void BackendDrain(BFRunloop *runloop) {
    (void)runloop;
}
#endif

static void BackendFree(BFRunloop *runloop) {
    if (!runloop) {
        return;
    }
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__linux__)
    if (runloop->backendType != BFRunloopBackendNone) {
        if (runloop->backendFd >= 0) {
            close(runloop->backendFd);
            runloop->backendFd = -1;
        }
    }
    if (runloop->backendType == BFRunloopBackendKqueue) {
        if (runloop->wakeupReadFd >= 0) {
            close(runloop->wakeupReadFd);
            runloop->wakeupReadFd = -1;
        }
        if (runloop->wakeupWriteFd >= 0) {
            close(runloop->wakeupWriteFd);
            runloop->wakeupWriteFd = -1;
        }
    } else if (runloop->backendType == BFRunloopBackendEpoll) {
        if (runloop->wakeupReadFd >= 0 && runloop->wakeupReadFd == runloop->wakeupWriteFd) {
            close(runloop->wakeupReadFd);
            runloop->wakeupReadFd  = -1;
            runloop->wakeupWriteFd = -1;
        }
    }
#endif
    runloop->backendType = BFRunloopBackendNone;
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
    rl->backendType    = BFRunloopBackendNone;
    rl->backendFd      = -1;
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__linux__)
    rl->wakeupReadFd   = -1;
    rl->wakeupWriteFd  = -1;
#endif
    rl->fdSources      = NULL;

#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__linux__)
    if (BackendInit(rl) != BF_OK) {
        rl->backendType = BFRunloopBackendNone;
        rl->backendFd   = -1;
    }
#else
    (void)BackendInit;
#endif
    return rl;
}

void BFRunloopFree(BFRunloop *runloop) {
    if (runloop == NULL) {
        return;
    }
    BFRunloopFdSource *source = runloop->fdSources;
    while (source) {
        BFRunloopFdSource *next = source->next;
        BFMemoryRelease(source);
        source = next;
    }
    BackendFree(runloop);

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

static int BFRunloopPostFromBackend(BFRunloop *runloop, const BFRunloopEvent *event) {
    pthread_mutex_lock(&runloop->mutex);
    int ok = QueuePush(&runloop->queue, event);
    pthread_mutex_unlock(&runloop->mutex);
    return ok;
}

#if defined(__APPLE__) || defined(__FreeBSD__)
static void BFRunloopBackendPoll(BFRunloop *runloop) {
    if (runloop->backendType != BFRunloopBackendKqueue) {
        return;
    }
    struct kevent events[8];
    int           ready = kevent(runloop->backendFd, NULL, 0, events, (int)(sizeof(events) / sizeof(events[0])), NULL);
    if (ready <= 0) {
        return;
    }
    for (int index = 0; index < ready; ++index) {
        struct kevent *kev = &events[index];
        if ((int)kev->ident == runloop->wakeupReadFd) {
            BackendDrain(runloop);
            continue;
        }
        BFRunloopFdSource *source = (BFRunloopFdSource *)kev->udata;
        if (!source) {
            continue;
        }
        (void)BFRunloopPostFromBackend(runloop, &source->eventTemplate);
    }
}
#elif defined(__linux__)
static void BFRunloopBackendPoll(BFRunloop *runloop) {
    if (runloop->backendType != BFRunloopBackendEpoll) {
        return;
    }
    struct epoll_event events[8];
    int                ready = epoll_wait(runloop->backendFd, events, (int)(sizeof(events) / sizeof(events[0])), -1);
    if (ready <= 0) {
        return;
    }
    for (int index = 0; index < ready; ++index) {
        struct epoll_event *ev = &events[index];
        if (ev->data.ptr == NULL) {
            BackendDrain(runloop);
            continue;
        }
        BFRunloopFdSource *source = (BFRunloopFdSource *)ev->data.ptr;
        if (!source) {
            continue;
        }
        (void)BFRunloopPostFromBackend(runloop, &source->eventTemplate);
    }
}
#else
static void BFRunloopBackendPoll(BFRunloop *runloop) {
    (void)runloop;
}
#endif

void BFRunloopRun(BFRunloop *runloop) {
    if (runloop == NULL) {
        return;
    }
    for (;;) {
        BFRunloopEvent event;
        int            haveEvent;

        pthread_mutex_lock(&runloop->mutex);
        haveEvent = QueuePop(&runloop->queue, &event);
        int stopping = runloop->stopping;
        pthread_mutex_unlock(&runloop->mutex);

        if (haveEvent == BF_OK) {
            if (event.type == BFRunloopEventStop) {
                pthread_mutex_lock(&runloop->mutex);
                runloop->stopping = 1;
                int empty         = (runloop->queue.count == 0U);
                pthread_mutex_unlock(&runloop->mutex);
                if (event.destroy != NULL && event.payload != NULL) {
                    event.destroy(event.payload);
                }
                if (empty != 0) {
                    break;
                }
                continue;
            }

            if (runloop->handler != NULL) {
                runloop->handler(runloop, &event, runloop->handlerContext);
            }

            if (event.destroy != NULL && event.payload != NULL) {
                event.destroy(event.payload);
            }
            continue;
        }

        if (stopping != 0) {
            break;
        }

        if (runloop->backendType != BFRunloopBackendNone) {
            BFRunloopBackendPoll(runloop);
            continue;
        }

        pthread_mutex_lock(&runloop->mutex);
        while (runloop->queue.count == 0U && runloop->stopping == 0) {
            pthread_cond_wait(&runloop->condition, &runloop->mutex);
        }
        pthread_mutex_unlock(&runloop->mutex);
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
        BackendSignal(runloop);
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
    BackendSignal(runloop);
}

void BFRunloopStop(BFRunloop *runloop, int drain) {
    if (runloop == NULL) {
        return;
    }
    if (drain == 0) {
        pthread_mutex_lock(&runloop->mutex);
        runloop->stopping = 2;
        BFRunloopEvent ev;
        while (QueuePop(&runloop->queue, &ev) == BF_OK) {
            if (ev.destroy != NULL && ev.payload != NULL) {
                ev.destroy(ev.payload);
            }
        }
        pthread_cond_signal(&runloop->condition);
        pthread_mutex_unlock(&runloop->mutex);
        BackendSignal(runloop);
    } else {
        BFRunloopPostStop(runloop);
    }
}

int BFRunloopAddFileDescriptor(BFRunloop *runloop,
                               int        fileDescriptor,
                               uint32_t   modes,
                               const BFRunloopEvent *templateEvent) {
    if (!runloop || fileDescriptor < 0 || !templateEvent) {
        return BF_ERR;
    }
#if !(defined(__APPLE__) || defined(__FreeBSD__) || defined(__linux__))
    (void)modes;
    return BF_ERR;
#else
    if (runloop->backendType == BFRunloopBackendNone) {
        return BF_ERR;
    }
    BFRunloopFdSource *source = (BFRunloopFdSource *)BFMemoryAllocate(sizeof(BFRunloopFdSource));
    if (!source) {
        return BF_ERR;
    }
    memset(source, 0, sizeof(BFRunloopFdSource));
    source->fileDescriptor = fileDescriptor;
    source->modes          = modes;
    source->eventTemplate  = *templateEvent;
    source->next           = NULL;

#if defined(__APPLE__) || defined(__FreeBSD__)
    struct kevent kev[2];
    int           kevCount = 0;
    if ((modes & BFRunloopFdModeRead) != 0U) {
        EV_SET(&kev[kevCount++], (uintptr_t)fileDescriptor, EVFILT_READ, EV_ADD, 0, 0, source);
    }
    if ((modes & BFRunloopFdModeWrite) != 0U) {
        EV_SET(&kev[kevCount++], (uintptr_t)fileDescriptor, EVFILT_WRITE, EV_ADD, 0, 0, source);
    }
    if (kevCount == 0) {
        BFMemoryRelease(source);
        return BF_ERR;
    }
    if (kevent(runloop->backendFd, kev, kevCount, NULL, 0, NULL) != 0) {
        BFMemoryRelease(source);
        return BF_ERR;
    }
#elif defined(__linux__)
    uint32_t events = 0;
    if ((modes & BFRunloopFdModeRead) != 0U) {
        events |= EPOLLIN;
    }
    if ((modes & BFRunloopFdModeWrite) != 0U) {
        events |= EPOLLOUT;
    }
    if (events == 0) {
        BFMemoryRelease(source);
        return BF_ERR;
    }
    struct epoll_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.events  = events;
    ev.data.ptr = source;
    if (epoll_ctl(runloop->backendFd, EPOLL_CTL_ADD, fileDescriptor, &ev) != 0) {
        BFMemoryRelease(source);
        return BF_ERR;
    }
#endif
    pthread_mutex_lock(&runloop->mutex);
    source->next       = runloop->fdSources;
    runloop->fdSources = source;
    pthread_mutex_unlock(&runloop->mutex);
    return BF_OK;
#endif
}

int BFRunloopRemoveFileDescriptor(BFRunloop *runloop, int fileDescriptor) {
    if (!runloop || fileDescriptor < 0) {
        return BF_ERR;
    }
#if !(defined(__APPLE__) || defined(__FreeBSD__) || defined(__linux__))
    (void)fileDescriptor;
    return BF_ERR;
#else
    pthread_mutex_lock(&runloop->mutex);
    BFRunloopFdSource **cursor = &runloop->fdSources;
    BFRunloopFdSource  *found  = NULL;
    while (*cursor) {
        if ((*cursor)->fileDescriptor == fileDescriptor) {
            found   = *cursor;
            *cursor = (*cursor)->next;
            break;
        }
        cursor = &(*cursor)->next;
    }
    pthread_mutex_unlock(&runloop->mutex);
    if (!found) {
        return BF_ERR;
    }
#if defined(__APPLE__) || defined(__FreeBSD__)
    struct kevent kev[2];
    int           kevCount = 0;
    if ((found->modes & BFRunloopFdModeRead) != 0U) {
        EV_SET(&kev[kevCount++], (uintptr_t)fileDescriptor, EVFILT_READ, EV_DELETE, 0, 0, NULL);
    }
    if ((found->modes & BFRunloopFdModeWrite) != 0U) {
        EV_SET(&kev[kevCount++], (uintptr_t)fileDescriptor, EVFILT_WRITE, EV_DELETE, 0, 0, NULL);
    }
    if (kevCount > 0) {
        (void)kevent(runloop->backendFd, kev, kevCount, NULL, 0, NULL);
    }
#elif defined(__linux__)
    (void)epoll_ctl(runloop->backendFd, EPOLL_CTL_DEL, fileDescriptor, NULL);
#endif
    BFMemoryRelease(found);
    return BF_OK;
#endif
}
