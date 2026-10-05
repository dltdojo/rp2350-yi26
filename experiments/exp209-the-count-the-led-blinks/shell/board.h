// SPDX-License-Identifier: Apache-2.0
// exp209 — what differs between the chip and the RTL: how a result is told.
#pragma once
#include <stdint.h>

// What a run found. Only `ok` leaves the chip — as slow or fast blinking —
// because a person reading an LED reliably reads one bit (see the README:
// revision 2's four numbers could not be read). The rest is for the RTL's
// print port, where it costs nothing to say.
struct result {
    uint32_t ok;         // checks 1, 3, 4, 5 and 6 passed, and minstret matched
    uint32_t failed;     // the failed checks as decimal digits, ascending
    uint32_t instret, pmpcfg, pmpaddr_xor, a0, cause;
};

void board_init(void);                                   // the LED on: alive
__attribute__((noreturn)) void board_report(const struct result *r);
__attribute__((noreturn)) void board_fault(uint32_t step, uint32_t cause);
