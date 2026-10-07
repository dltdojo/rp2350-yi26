// SPDX-License-Identifier: Apache-2.0
// exp216 — what differs between the chip and the RTL: the registers, and how
// a result is told.
#pragma once
#include <stdint.h>

// Verdicts. 0 is slow blinking on the chip; the rest are counted flashes.
#define V_OK        0u
#define V_RESET     1u   // PIO0 never reported out of reset
#define V_SILENT    2u   // a command went in and no answer came back
#define V_ANSWER    3u   // the answer was not the command
#define V_SIO       4u   // told 0, the pin read 1: SIO's level, so PIO was not driving it
#define V_PIN       5u   // told 1, the pin read 0
#define V_LEFTOVER  6u   // a FIFO was not empty at the end

uint32_t rd(uint32_t addr);
void wr(uint32_t addr, uint32_t v);
void board_init(void);                                       // the LED on: alive, SIO driving it high
__attribute__((noreturn)) void board_report(uint32_t verdict, uint32_t command);
__attribute__((noreturn)) void board_fault(uint32_t step, uint32_t cause);
