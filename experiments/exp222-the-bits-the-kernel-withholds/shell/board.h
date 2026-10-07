// SPDX-License-Identifier: Apache-2.0
// exp222 — what differs between the chip and the RTL: where the samples come
// from, and how a result is told.
#pragma once
#include <stdint.h>

// Verdicts. 0 is slow blinking on the chip; the rest are counted flashes.
#define V_OK        0u   // the TRNG's samples passed and were copied; both bad sources were withheld
#define V_KERNEL    1u   // the kernel's bytes, its halting, its count, or the memory it left
#define V_SILENT    2u   // the TRNG gave nothing within its timeout
#define V_WITHHELD  3u   // the TRNG's own samples failed a health test: HALT 1
#define V_LET_PASS  4u   // a source built to fail was passed: HALT 0

struct result {
    uint32_t verdict;
    uint32_t source;      // 0 the TRNG, 1 stuck at 1, 2 nine ones then a zero
    uint32_t failed;      // the failed checks as decimal digits
    uint32_t a0, instret, cause;
};

void board_init(void);                                       // the LED on: alive
// `n` words from the TRNG; 0 if it gave nothing within its timeout.
int board_trng(uint32_t *words, uint32_t n);
__attribute__((noreturn)) void board_report(const struct result *r);
__attribute__((noreturn)) void board_fault(uint32_t step, uint32_t cause);
