// SPDX-License-Identifier: Apache-2.0
// exp209 — what differs between the chip and the RTL: how a result is told.
#pragma once
#include <stdint.h>

// What a run reports, in the order the LED blinks it.
enum { NUMBERS = 4 };
struct result {
    // [0] the failed checks as decimal digits, ascending (26: checks 2 and 6;
    //     0: none); [1] minstret; [2] pmpcfg0's low byte as read back;
    //     [3] pmpaddr0 as read back XOR as written (0: the same)
    uint32_t number[NUMBERS];
    uint32_t cycles, a0, cause;
};

void board_init(void);                                   // the LED on: alive
__attribute__((noreturn)) void board_report(const struct result *r);
__attribute__((noreturn)) void board_fault(uint32_t step, uint32_t cause);
