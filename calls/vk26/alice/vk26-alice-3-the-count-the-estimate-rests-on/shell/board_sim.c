// SPDX-License-Identifier: Apache-2.0
//
// vk26-alice-3 — the same shell on the Hazard3 RTL: the testbench's print port
// instead of USB and an LED, the region hashed in software, a stand-in for
// the TRNG — both kinds of draw, the same words — and one round instead of
// forever.
//
//   STRM s most want minstret mcycle    one stream run
//   DONE streams, FAIL, FAUL            alice/shell/sim.h's

#include "board.h"
#include "sim.h"

int board_trng_raw(uint32_t *words, uint32_t n) { return board_trng(words, n); }

void board_stream(uint32_t round, uint32_t s, const char *name, const uint32_t *words, const uint32_t *counts,
                  uint32_t most, uint32_t want, uint32_t instret, uint32_t cycles) {
    (void)round;
    (void)name;
    (void)words;
    (void)counts;
    IO_PRINT_U32 = 0x5354524du;   // "STRM"
    IO_PRINT_U32 = s;
    IO_PRINT_U32 = most;
    IO_PRINT_U32 = want;
    IO_PRINT_U32 = instret;
    IO_PRINT_U32 = cycles;
}
