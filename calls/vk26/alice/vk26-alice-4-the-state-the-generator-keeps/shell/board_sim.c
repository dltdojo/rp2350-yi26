// SPDX-License-Identifier: Apache-2.0
//
// vk26-alice-4 — the same shell on the Hazard3 RTL: the testbench's print port
// instead of USB and an LED, HASHB and the region hashed in software, and one
// round instead of forever.
//
//   CASE i minstret mcycle minstret mcycle minstret mcycle
//                                       one case: its three runs
//   DONE cases, FAIL, FAUL              alice/shell/sim.h's

#include "board.h"
#include "sim.h"

static uint32_t runs[6];

int board_hashb(const uint8_t *src, uint32_t len, uint8_t *dst) { return board_hash(src, len, dst); }

void board_state(uint32_t round, uint32_t i, const uint8_t *v, const uint8_t *c) {
    (void)round;
    (void)i;
    (void)v;
    (void)c;
}

void board_run(uint32_t round, uint32_t i, uint32_t n, uint32_t code, uint32_t counter, uint32_t instret,
               uint32_t cycles, const uint8_t *blocks, uint32_t nblocks, const uint8_t *v) {
    (void)round;
    (void)i;
    (void)code;
    (void)counter;
    (void)blocks;
    (void)nblocks;
    (void)v;
    runs[2 * (n - 1)] = instret;
    runs[2 * (n - 1) + 1] = cycles;
}

void board_case(uint32_t round, uint32_t i, const char *name) {
    (void)round;
    (void)name;
    IO_PRINT_U32 = 0x43415345u;   // "CASE"
    IO_PRINT_U32 = i;
    for (uint32_t k = 0; k < 6; k++) IO_PRINT_U32 = runs[k];
}
