#include "box/BFCommon.h"

#include <stdio.h>
#include <stdlib.h>

void BFFatal(const char *message) {
    perror(message);
    exit(EXIT_FAILURE);
}
