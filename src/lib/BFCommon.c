#include "box/BFCommon.h"

#include <stdlib.h>
#include <stdio.h>

void BFFatal(const char *message) {
    perror(message);
    exit(EXIT_FAILURE);
}
