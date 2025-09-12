#include "box/BFRunloop.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

typedef struct CounterCtx {
    int count;
} CounterCtx;

static void handler(BFRunloop *runloop, BFRunloopEvent *event, void *context) {
    (void)runloop;
    CounterCtx *counter = (CounterCtx *)context;
    if (event->type != BFRunloopEventStop) {
        counter->count++;
    }
}

int main(void) {
    BFRunloop *runloop = BFRunloopCreate();
    assert(runloop != NULL);
    CounterCtx context = {0};
    assert(BFRunloopSetHandler(runloop, handler, &context) == 0);
    assert(BFRunloopStart(runloop) == 0);

    for (int index = 0; index < 10; ++index) {
        BFRunloopEvent event;
        memset(&event, 0, sizeof(event));
        event.type = 100;
        assert(BFRunloopPost(runloop, &event) == 0);
    }

    BFRunloopPostStop(runloop);
    BFRunloopJoin(runloop);
    BFRunloopFree(runloop);

    assert(context.count == 10);
    printf("test_BFRunloop: OK\n");
    return 0;
}
