// SPDX-License-Identifier: Apache-2.0
// exp220 — what differs between the chip and the RTL: the PIO blocks'
// registers, and how a result is told.
#pragma once
#include <stdint.h>

// Verdicts. 0 is slow blinking on the chip; the rest are counted flashes.
#define V_OK        0u
#define V_KERNEL    1u   // the CPU side: one of exp209's checks, or minstret
#define V_RESET0    2u   // PIO0 never reported out of reset
#define V_RESET1    3u   // PIO1 never reported out of reset
#define V_BUSY      4u   // a block was not waiting, FIFOs empty, while the kernel ran
#define V_SILENT    5u   // a word went into a block and nothing came back
#define V_INVERT    6u   // PIO0 gave back something other than the word complemented
#define V_REVERSE   7u   // PIO1 gave back something other than the word reversed
#define V_ORDER     8u   // the two orders did not both give ANSWERS
#define V_LEFTOVER  9u   // a FIFO was not empty at the end

struct result {
    uint32_t verdict;
    uint32_t failed;     // the CPU side's failed checks as decimal digits, as exp209's
    uint32_t instret, a0, cause;
    uint32_t word, block; // the word, 0..15, and the block (0 or 1) a verdict is about
};

uint32_t rd(uint32_t addr);
void wr(uint32_t addr, uint32_t v);
void board_init(void);                                       // the LED on: alive
__attribute__((noreturn)) void board_report(const struct result *r);
__attribute__((noreturn)) void board_fault(uint32_t step, uint32_t cause);
