// SPDX-License-Identifier: Apache-2.0
//
// exp223 — the same shell on the Hazard3 RTL. The kernel runs for real there;
// the RTL has no TRNG, so tools/hazard3/shell/trng_sim.h stands in, chosen
// with -DDEVICE= (0 works, 1 all ones, 2 nothing), and no SHA-256 block, so
// the digest is held against tools/hazard3/harness/sha256.c.
//
//   REPT verdict source failed a0 minstret cause    the shell's result
//   FAUL step cause                                 the shell itself trapped

#include "board.h"
#include "sha256.h"
#include "trng_sim.h"

void board_init(void) {}

int board_sha(const uint8_t *src, uint32_t len, uint8_t *dst) {
    sha256(src, len, dst);
    return 1;
}

#include "report_sim.h"
