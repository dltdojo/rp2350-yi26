// SPDX-License-Identifier: Apache-2.0
//
// tools/hazard3/shell — a health-test shell's verdict on the LED (led.h,
// included first): slow blinking for V_OK, a count of flashes for any other
// verdict, and led_fault for the shell's own trap. `struct result` and V_OK
// are the includer's board.h's. exp222 wrote it, exp223 needed it second.
#pragma once

void board_report(const struct result *r) {
    if (r->verdict == V_OK) led_verdict(1);
    led_count(r->verdict);
}

void board_fault(uint32_t step, uint32_t cause) {
    (void)step;
    (void)cause;
    led_fault();
}
