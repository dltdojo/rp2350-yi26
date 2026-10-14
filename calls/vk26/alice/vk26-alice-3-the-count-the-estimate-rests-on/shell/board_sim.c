// SPDX-License-Identifier: Apache-2.0
//
// vk26-alice-3 — the same shell on the Hazard3 RTL: the testbench's print port
// instead of USB and an LED, the region hashed in software, a stand-in for
// the TRNG — both kinds of draw, the same words — and one round instead of
// forever.
//
//   STRM s most want minstret mcycle minstret mcycle
//                                       one stream: both runs
//   PROB i addr minstret mcycle accesses misses
//                                       one probe run; no cache here, so
//                                       nothing is evicted and both counts are 0
//   DONE streams, FAIL, FAUL            alice/shell/sim.h's

#include "board.h"
#include "sim.h"

int board_trng_raw(uint32_t *words, uint32_t n) { return board_trng(words, n); }

void board_evict(uint32_t addr) { (void)addr; }
void board_xip_clear(void) {}
void board_xip(uint32_t *acc, uint32_t *hit) { *acc = *hit = 0; }

void board_probe(uint32_t round, uint32_t i, uint32_t addr, uint32_t instret, uint32_t cycles, uint32_t acc,
                 uint32_t miss) {
    (void)round;
    IO_PRINT_U32 = 0x50524f42u;   // "PROB"
    IO_PRINT_U32 = i;
    IO_PRINT_U32 = addr;
    IO_PRINT_U32 = instret;
    IO_PRINT_U32 = cycles;
    IO_PRINT_U32 = acc;
    IO_PRINT_U32 = miss;
}

void board_stream(uint32_t round, uint32_t s, const char *name, const uint32_t *words, const uint32_t *counts,
                  uint32_t most, uint32_t want, uint32_t instret, uint32_t cycles, uint32_t again_instret,
                  uint32_t again_cycles) {
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
    IO_PRINT_U32 = again_instret;
    IO_PRINT_U32 = again_cycles;
}
