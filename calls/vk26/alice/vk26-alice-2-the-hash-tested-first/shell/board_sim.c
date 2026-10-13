// SPDX-License-Identifier: Apache-2.0
//
// vk26-alice-2 — the same shell on the Hazard3 RTL: the testbench's print port
// instead of USB and an LED, HASH in software, a stand-in for the TRNG, and
// one round instead of forever.
//
//   STRM s code want minstret spoil     one stream run
//   DONE streams, FAIL, FAUL            alice/shell/sim.h's

#include "board.h"
#include "sim.h"

void board_stream(uint32_t round, uint32_t s, const char *name, const uint32_t *bits, uint32_t code,
                  uint32_t want, uint32_t instret, uint32_t spoil, const uint8_t *kat, const uint8_t *output) {
    (void)round;
    (void)name;
    (void)bits;
    (void)kat;
    (void)output;
    IO_PRINT_U32 = 0x5354524du;   // "STRM"
    IO_PRINT_U32 = s;
    IO_PRINT_U32 = code;
    IO_PRINT_U32 = want;
    IO_PRINT_U32 = instret;
    IO_PRINT_U32 = spoil;
}
