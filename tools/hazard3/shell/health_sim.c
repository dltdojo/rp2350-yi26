// SPDX-License-Identifier: Apache-2.0
//
// tools/hazard3/shell — the same board on the Hazard3 RTL. The RTL has no TRNG,
// so trng_sim.h stands in, chosen with -DDEVICE= (0 works, 1 all ones, 2
// nothing), and no SHA-256 block, so board_sha is tools/hazard3/harness/
// sha256.c. board.h is the includer's. exp223 wrote it, exp224 needed it
// second.
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
