// SPDX-License-Identifier: Apache-2.0
// exp218 — what differs between the chip and the RTL: the registers, and how
// a result is told.
#pragma once
#include <stdint.h>

uint32_t rd(uint32_t addr);
void wr(uint32_t addr, uint32_t v);
void board_init(void);                                  // the LED on: alive
// The verdict: 0 is every case as the model says; otherwise bit k set for
// each case k + 1 the chip disagreed on. `reset` instead: PIO0 never came
// out of reset, before case `failed_case`.
__attribute__((noreturn)) void board_report(uint32_t failed, uint32_t fields_of_first);
__attribute__((noreturn)) void board_reset_failed(uint32_t failed_case);
__attribute__((noreturn)) void board_fault(uint32_t step, uint32_t cause);
