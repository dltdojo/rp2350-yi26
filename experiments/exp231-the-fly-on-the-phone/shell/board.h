// SPDX-License-Identifier: Apache-2.0
// exp231 — what differs between the chip and the RTL: how a round is shown.
#pragma once
#include <stdint.h>

#define N 256

// One round: a life of Rule 30 and what the fly saw of it.
struct round {
    uint32_t round;          // 0 from SEED0, then each from the last's last generation
    uint32_t seed;           // frame 0; life[g] is frame g + 1
    uint32_t instret;        // minstret for the life's kernel
    uint32_t fly_instret;    // minstret for the fly's kernel
    uint32_t up, down;       // the fly's totals, from 0x100 and 0x104
    uint32_t life[N];        // the 256 generations, from 0x200 of the life's region
    uint32_t steps[2 * N];   // step g: up at 2g, down at 2g + 1, from 0x800 of the fly's
};

void board_init(void);
// On the chip a LIFE, FLY and SEED line, then a SEES line and a beat on the
// LED for each step; on the RTL, two lines, and after two rounds the end.
void board_play(const struct round *r);
// A check failed: 1 to 4 exp225's (the life's kernel bytes, no HALT 0,
// minstret, the first life not rule30.py's); 10 the fly's kernel bytes, 11 no
// HALT 0, 12 minstret, 13 the first round's steps not fly.py's, 14 a step
// seen moving down more than up. On the chip, that many flashes after a long
// light, forever.
__attribute__((noreturn)) void board_fail(uint32_t check, uint32_t got);
__attribute__((noreturn)) void board_fault(uint32_t step, uint32_t cause);
