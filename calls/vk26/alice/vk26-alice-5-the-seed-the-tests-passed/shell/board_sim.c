// SPDX-License-Identifier: Apache-2.0
//
// vk26-alice-5 — the same shell on the Hazard3 RTL: the testbench's print port
// instead of USB and an LED, HASH and HASHB in software, the TRNG's stand-in,
// and one round instead of forever.
//
//   CASE i minstret mcycle × 3              one NIST case: its three runs
//   CHN s code minstret mcycle [minstret mcycle × 2]
//                                           one chain: alice-2's kernel, then
//                                           with code 0 Instantiate and Generate
//   DONE cases, FAIL, FAUL                  alice/shell/sim.h's

#include "board.h"
#include "sim.h"

int board_hashb(const uint8_t *src, uint32_t len, uint8_t *dst) { return board_hash(src, len, dst); }

void board_nist(uint32_t round, uint32_t i, const char *name, const uint8_t *seed, uint32_t s, const uint8_t *v,
                const uint8_t *c, const uint8_t *blocks, const uint32_t *runs) {
    (void)round;
    (void)name;
    (void)seed;
    (void)s;
    (void)v;
    (void)c;
    (void)blocks;
    IO_PRINT_U32 = 0x43415345u;   // "CASE"
    IO_PRINT_U32 = i;
    for (uint32_t k = 0; k < 6; k++) IO_PRINT_U32 = runs[k];
}

void board_chain(uint32_t round, uint32_t s, const uint32_t *bits, uint32_t spoil, const uint8_t *kat, uint32_t code,
                 const uint32_t *trust, const uint8_t *digest, const uint8_t *v, const uint8_t *c,
                 const uint8_t *blocks, const uint32_t *runs) {
    (void)round;
    (void)bits;
    (void)spoil;
    (void)kat;
    (void)v;
    (void)c;
    (void)blocks;
    IO_PRINT_U32 = 0x43484e00u;   // "CHN"
    IO_PRINT_U32 = s;
    IO_PRINT_U32 = code;
    IO_PRINT_U32 = trust[0];
    IO_PRINT_U32 = trust[1];
    if (digest)
        for (uint32_t k = 0; k < 4; k++) IO_PRINT_U32 = runs[k];
}
