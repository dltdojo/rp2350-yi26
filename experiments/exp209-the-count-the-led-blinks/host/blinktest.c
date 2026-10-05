// SPDX-License-Identifier: Apache-2.0
//
// exp209 — shell/blink.c, compiled for this machine with a recorder in place
// of the LED: prints one round as a line of holds, `+n` on and `-n` off, with
// neighbouring holds of the same state merged, which is what an eye sees.
//
//   blinktest report FAILED NUMBER
//   blinktest fault STEP

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "blink.h"

static int last = -1;
static unsigned run;

static void flush(void) {
    if (last >= 0) printf("%c%u ", last ? '+' : '-', run);
}

static void record(int on, uint32_t units) {
    if (on == last) {
        run += units;
        return;
    }
    flush();
    last = on;
    run = units;
}

int main(int argc, char **argv) {
    if (argc == 4 && !strcmp(argv[1], "report"))
        blink_report(record, (uint32_t)atoi(argv[2]), (uint32_t)atoi(argv[3]));
    else if (argc == 3 && !strcmp(argv[1], "fault"))
        blink_fault(record, (uint32_t)atoi(argv[2]));
    else
        return 2;
    flush();
    printf("\n");
    return 0;
}
