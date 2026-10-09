// SPDX-License-Identifier: Apache-2.0
// exp225 — what differs between the chip and the RTL: how a life is shown.
#pragma once
#include <stdint.h>

#define N 256

void board_init(void);                                    // the LED on: alive
// One life, as it is shown: on the chip the centre cell of each generation
// on the LED, a beat each; on the RTL, a line, and after two lives, the end.
void board_play(const uint32_t *life, uint32_t round, uint32_t instret);
// A check failed: 1 kernel.bin's hash, 2 no HALT 0, 3 minstret, 4 the first
// life is not rule30.py's. On the chip, that many flashes and a pause, forever.
__attribute__((noreturn)) void board_fail(uint32_t check, uint32_t got);
__attribute__((noreturn)) void board_fault(uint32_t step, uint32_t cause);
