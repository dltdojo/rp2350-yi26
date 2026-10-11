// SPDX-License-Identifier: Apache-2.0
// exp228 — what differs between the chip and the RTL: how a verdict is shown.
#pragma once
#include <stdint.h>

void board_init(void);
// One case run: its exit code, script.py's verdict, minstret, and how many
// signatures the shell checked for it and found valid.
void board_case(uint32_t round, uint32_t i, const char *name, uint32_t code, uint32_t want, uint32_t instret,
                uint32_t sigs, uint32_t valid);
// Every case run and as it should be. On the RTL, the end; on the chip, a
// pause, and the cases again.
void board_round(uint32_t round, uint32_t cases);
// A check failed: 1 the kernel's bytes are not kernel.sha256's, 2 a case's
// exit code is not its verdict, 3 minstret is not the model's count, 4 the
// kernel trapped other than by a call or a halt, or called with arguments the
// model refuses. (5 to 9 are speak.h's, the clocks' and USB's.)
__attribute__((noreturn)) void board_fail(uint32_t check, uint32_t got);
__attribute__((noreturn)) void board_fault(uint32_t step, uint32_t cause);
