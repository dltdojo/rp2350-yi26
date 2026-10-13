// SPDX-License-Identifier: Apache-2.0
//
// calls/vk26/alice/shell — what alice's shells on the Hazard3 RTL do the same
// way: no board to bring up, HASH in software (tools/hazard3/harness/
// sha256.c), the TRNG's stand-in (tools/hazard3/shell/trng_sim.h, -DDEVICE=),
// and after one round of streams
//
//   DONE streams          every stream run and as it should be; exit 0
//
// with fail_sim.h's FAIL and FAUL for everything else. vk26-alice-1 wrote it,
// vk26-alice-2 is the second to need it. Included by a board_sim.c after its
// board.h; the board_stream that prints a stream is the experiment's own.
#pragma once
#include <stdint.h>
#include "fail_sim.h"
#include "sha256.h"
#include "trng_sim.h"

void board_init(void) {}

int board_hash(const uint8_t *src, uint32_t len, uint8_t *dst) {
    sha256(src, len, dst);
    return 1;
}

void board_round(uint32_t round, uint32_t streams) {
    (void)round;
    IO_PRINT_U32 = 0x444f4e45u;   // "DONE"
    IO_PRINT_U32 = streams;
    IO_EXIT = 0;
    for (;;) {}
}
