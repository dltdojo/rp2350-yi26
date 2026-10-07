// SPDX-License-Identifier: Apache-2.0
// exp219 — what differs between the chip and the RTL: the PIO's registers,
// and how a result is told.
#pragma once
#include <stdint.h>

// Verdicts. 0 is slow blinking on the chip; the rest are counted flashes.
#define V_OK        0u
#define V_KERNEL    1u   // the CPU side: one of exp209's checks, or minstret
#define V_RESET     2u   // PIO0 never reported out of reset
#define V_BUSY      3u   // PIO0 was not waiting, with both FIFOs empty, while the kernel ran
#define V_SILENT    4u   // a word went in and nothing came back
#define V_WRONG     5u   // what came back was not the copied word, complemented
#define V_LEFTOVER  6u   // a FIFO was not empty at the end

// What the run found; the chip shows `verdict`, the RTL prints it all.
struct result {
    uint32_t verdict;
    uint32_t failed;     // the CPU side's failed checks as decimal digits, as exp209's
    uint32_t instret, a0, cause, word;
};

uint32_t rd(uint32_t addr);
void wr(uint32_t addr, uint32_t v);
void board_init(void);                                       // the LED on: alive
__attribute__((noreturn)) void board_report(const struct result *r);
__attribute__((noreturn)) void board_fault(uint32_t step, uint32_t cause);
