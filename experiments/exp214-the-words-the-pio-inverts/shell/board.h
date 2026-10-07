// SPDX-License-Identifier: Apache-2.0
// exp214 — what differs between the chip and the RTL: the registers, and how
// a result is told.
#pragma once
#include <stdint.h>

// Verdicts. 0 is slow blinking on the chip; the rest are counted flashes.
#define V_OK        0u
#define V_RESET     1u   // PIO0 never reported out of reset
#define V_SILENT    2u   // a word went in and nothing came back
#define V_ECHO      3u   // what came back was the word itself, not its complement
#define V_WRONG     4u   // what came back was something else
#define V_LEFTOVER  5u   // a FIFO was not empty at the end

uint32_t rd(uint32_t addr);
void wr(uint32_t addr, uint32_t v);
void board_init(void);                                       // the LED on: alive
__attribute__((noreturn)) void board_report(uint32_t verdict, uint32_t word);
__attribute__((noreturn)) void board_fault(uint32_t step, uint32_t cause);
