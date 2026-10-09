// SPDX-License-Identifier: Apache-2.0
// exp224 — what differs between the chip and the RTL: where the samples come
// from, who computes SHA-256, and how a result is told
// (tools/hazard3/shell/health_chip.c and health_sim.c).
#pragma once
#include <stdint.h>

// Verdicts. 0 is slow blinking on the chip; the rest are counted flashes.
// 0, 1, 3 and 4 are the judge's, proof/Judge.lean's; 2 and 5 are the shell's.
#define V_OK        0u   // all three sources as exp223's `conditions` says: the judge halted with 0
#define V_KERNEL    1u   // a check failed: the judge's code says which source, and which checks
#define V_SILENT    2u   // the TRNG gave nothing within its timeout, before anything ran
#define V_WITHHELD  3u   // the TRNG's own samples failed a health test: HALT 1
#define V_LET_PASS  4u   // a source built to fail was passed: HALT 0
#define V_JUDGE     5u   // the judge's bytes were not judge.sha256's, or it did not HALT

struct result {
    uint32_t verdict;
    uint32_t source;      // the judge's code, bits 3..5
    uint32_t failed;      // the judge's code, bits 6..10: check k failed is bit k - 1
    uint32_t a0, instret, cause;   // the judge's code, minstret and mcause
};

void board_init(void);                                       // the LED on: alive
// `n` words from the TRNG; 0 if it gave nothing within its timeout.
int board_trng(uint32_t *words, uint32_t n);
// SHA-256 of `len` bytes at `src` (a multiple of 64, word-aligned): the
// chip's SHA-256 block on the chip, sha256.c on the RTL. 0 on an error.
int board_sha(const uint8_t *src, uint32_t len, uint8_t *dst);
__attribute__((noreturn)) void board_report(const struct result *r);
__attribute__((noreturn)) void board_fault(uint32_t step, uint32_t cause);
