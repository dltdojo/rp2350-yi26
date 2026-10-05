// SPDX-License-Identifier: Apache-2.0
// exp209 — what differs between the chip and the RTL: how a result is told.
#pragma once
#include <stdint.h>

struct result {
    uint32_t failed;     // 0: every check passed; else the first that did not
    uint32_t number;     // minstret, or mcause when the payload did not halt
    uint32_t instret, cycles, a0, cause;
};

void board_init(void);                                   // the LED on: alive
__attribute__((noreturn)) void board_report(const struct result *r);
__attribute__((noreturn)) void board_fault(uint32_t step, uint32_t cause);
