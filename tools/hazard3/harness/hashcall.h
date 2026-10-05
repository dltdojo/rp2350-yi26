// SPDX-License-Identifier: Apache-2.0
//
// tools/hazard3/harness — whether a HASH call's arguments are ones the model
// accepts (lean/Rv32/Machine.lean's `syscall`): a1 a multiple of 64, a0 and a2
// word-aligned, a1 bytes at a0 and 32 at a2 inside the region. Anything else
// is a fault. Shared by the RTL harness's handler.c and the chip shells, so
// that the rule a payload is held to cannot differ between them. REGION and
// REGION_SIZE are the includer's.
#pragma once
#include <stdint.h>

static int inside(uint32_t a, uint32_t n) {
    return a >= REGION && n <= REGION_SIZE && a - REGION <= REGION_SIZE - n;
}

static int hash_args_ok(uint32_t src, uint32_t len, uint32_t dst) {
    return len % 64 == 0 && src % 4 == 0 && dst % 4 == 0 && inside(src, len) && inside(dst, 32);
}
