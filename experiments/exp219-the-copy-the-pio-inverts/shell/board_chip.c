// SPDX-License-Identifier: Apache-2.0
//
// exp219 — the Pico 2: PIO0's registers for real, and the verdict on the LED
// (tools/hazard3/shell/led.h): slow blinking for ok, a count of flashes for
// anything else.

#include "board.h"
#include "led.h"

uint32_t rd(uint32_t addr) { return REG(addr); }
void wr(uint32_t addr, uint32_t v) { REG(addr) = v; }

void board_init(void) { led_init(); }

void board_report(const struct result *r) {
    if (r->verdict == V_OK) led_verdict(1);
    led_count(r->verdict);
}

void board_fault(uint32_t step, uint32_t cause) {
    (void)step;
    (void)cause;
    led_fault();
}
