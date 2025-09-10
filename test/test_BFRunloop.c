#include "box/BFRunloop.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

typedef struct CounterCtx {
    int count;
} CounterCtx;

static void handler(BFRunloop *rl, BFRunloopEvent *ev, void *ctx) {
    (void)rl;
    CounterCtx *c = (CounterCtx *)ctx;
    if (ev->type != BFRunloopEventStop) {
        c->count++;
    }
}

int main(void) {
    BFRunloop *rl = BFRunloopCreate();
    assert(rl != NULL);
    CounterCtx ctx = {0};
    assert(BFRunloopSetHandler(rl, handler, &ctx) == 0);
    assert(BFRunloopStart(rl) == 0);

    for (int i = 0; i < 10; ++i) {
        BFRunloopEvent ev;
        memset(&ev, 0, sizeof(ev));
        ev.type = 100;
        assert(BFRunloopPost(rl, &ev) == 0);
    }

    BFRunloopPostStop(rl);
    BFRunloopJoin(rl);
    BFRunloopFree(rl);

    assert(ctx.count == 10);
    printf("test_BFRunloop: OK\n");
    return 0;
}
