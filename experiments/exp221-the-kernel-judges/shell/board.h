// SPDX-License-Identifier: Apache-2.0
// exp221 — what differs between the chip and the RTL: the PIO blocks'
// registers, and how a result is told.
#pragma once
#include <stdint.h>

// Verdicts. 0 is slow blinking on the chip; the rest are counted flashes.
#define V_OK        0u   // the kernel judged the two orders the same: HALT 0
#define V_KERNEL    1u   // the kernel's bytes, its halting, memory it left, or minstret
#define V_RESET0    2u   // PIO0 never reported out of reset
#define V_RESET1    3u   // PIO1 never reported out of reset
#define V_SILENT    4u   // a word went into a block and nothing came back
#define V_INVERT    5u   // PIO0 gave back something other than the word complemented
#define V_REVERSE   6u   // PIO1 gave back something other than the word reversed
#define V_DIFFER    7u   // the kernel judged the two orders different: HALT 1
#define V_LEFTOVER  8u   // a FIFO was not empty before the kernel ran

struct result {
    uint32_t verdict;
    uint32_t failed;     // the kernel's failed checks as decimal digits
    uint32_t instret, a0, cause;
    uint32_t word, block; // the word, 0..15, and the block (0 or 1) a verdict is about
};

uint32_t rd(uint32_t addr);
void wr(uint32_t addr, uint32_t v);
void board_init(void);                                       // the LED on: alive
__attribute__((noreturn)) void board_report(const struct result *r);
__attribute__((noreturn)) void board_fault(uint32_t step, uint32_t cause);
