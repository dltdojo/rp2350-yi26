// SPDX-License-Identifier: Apache-2.0
//
// exp231 — the same shell on the Hazard3 RTL: the testbench's print port
// instead of an LED and USB, and two rounds instead of forever.
//
//   LIFE round minstret gen1 gen256 centre-bits-0-31 of the life
//   FLY  round minstret up down steps-seen-moving-up steps-seen-not-moving
//   FAIL check got                     a check failed
//   FAUL step cause                    the shell itself trapped

#include "board.h"
#include "fail_sim.h"

#define CENTRE 16

void board_init(void) {}

void board_play(const struct round *r) {
    uint32_t col = 0, ups = 0, stills = 0;
    for (uint32_t g = 0; g < 32; g++) col |= ((r->life[g] >> CENTRE) & 1) << g;
    for (uint32_t g = 0; g < N; g++) {
        if (r->steps[2 * g] > r->steps[2 * g + 1]) ups++;
        if (r->steps[2 * g] == r->steps[2 * g + 1]) stills++;
    }
    IO_PRINT_U32 = 0x4c494645u;   // "LIFE"
    IO_PRINT_U32 = r->round;
    IO_PRINT_U32 = r->instret;
    IO_PRINT_U32 = r->life[0];
    IO_PRINT_U32 = r->life[N - 1];
    IO_PRINT_U32 = col;
    IO_PRINT_U32 = 0x464c5920u;   // "FLY "
    IO_PRINT_U32 = r->round;
    IO_PRINT_U32 = r->fly_instret;
    IO_PRINT_U32 = r->up;
    IO_PRINT_U32 = r->down;
    IO_PRINT_U32 = ups;
    IO_PRINT_U32 = stills;
    if (r->round == 1) {
        IO_EXIT = 0;
        for (;;) {}
    }
}
