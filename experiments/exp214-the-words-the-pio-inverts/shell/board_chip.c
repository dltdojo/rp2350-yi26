// SPDX-License-Identifier: Apache-2.0
//
// exp214 — the Pico 2: PIO0's registers for real, and the verdict on the LED
// (tools/hazard3/shell/led.h): slow blinking when every word came back
// complemented, otherwise the verdict's number as counted flashes.

#include "board.h"
#include "led.h"

uint32_t rd(uint32_t addr) { return REG(addr); }
void wr(uint32_t addr, uint32_t v) { REG(addr) = v; }

void board_init(void) { led_init(); }

void board_report(uint32_t verdict, uint32_t word) {
    (void)word;
    if (verdict == V_OK) led_verdict(1);
    led_count(verdict);
}

void board_fault(uint32_t step, uint32_t cause) {
    (void)step;
    (void)cause;
    led_fault();
}
