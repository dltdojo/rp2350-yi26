// SPDX-License-Identifier: Apache-2.0
//
// vk26-alice-1 — the same shell on the Hazard3 RTL: the testbench's print port
// instead of USB and an LED, HASH in software, a stand-in for the TRNG
// (tools/hazard3/shell/trng_sim.h, -DDEVICE=), and one round instead of
// forever.
//
//   STRM s code want minstret digests   one stream run
//   DONE streams                        every stream as it should be
//   FAIL check got, FAUL step cause     fail_sim.h's

#include "board.h"
#include "fail_sim.h"
#include "sha256.h"
#include "trng_sim.h"

void board_init(void) {}

int board_hash(const uint8_t *src, uint32_t len, uint8_t *dst) {
    sha256(src, len, dst);
    return 1;
}

void board_stream(uint32_t round, uint32_t s, const char *name, const uint32_t *bits, uint32_t code,
                  uint32_t want, uint32_t instret, const uint8_t (*digest)[32], uint32_t ndigests) {
    (void)round;
    (void)name;
    (void)bits;
    (void)digest;
    IO_PRINT_U32 = 0x5354524du;   // "STRM"
    IO_PRINT_U32 = s;
    IO_PRINT_U32 = code;
    IO_PRINT_U32 = want;
    IO_PRINT_U32 = instret;
    IO_PRINT_U32 = ndigests;
}

void board_round(uint32_t round, uint32_t streams) {
    (void)round;
    IO_PRINT_U32 = 0x444f4e45u;   // "DONE"
    IO_PRINT_U32 = streams;
    IO_EXIT = 0;
    for (;;) {}
}
