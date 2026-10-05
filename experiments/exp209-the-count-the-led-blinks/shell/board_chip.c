// SPDX-License-Identifier: Apache-2.0
//
// exp209 — the Pico 2: the verdict on the LED, slow or fast, and nothing else
// (tools/hazard3/shell/led.h).

#include "board.h"
#include "led.h"

void board_init(void) { led_init(); }

void board_report(const struct result *r) { led_verdict(r->ok); }

void board_fault(uint32_t step, uint32_t cause) {
    (void)step;
    (void)cause;
    led_fault();
}
