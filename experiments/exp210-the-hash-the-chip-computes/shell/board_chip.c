// SPDX-License-Identifier: Apache-2.0
//
// exp210 — the Pico 2: HASH on the SHA-256 block (tools/hazard3/shell/
// sha_chip.h), and the verdict on the LED, slow or fast (led.h). Nothing per case
// leaves the chip; the RTL build prints that.

#include "board.h"
#include "led.h"
#include "sha_chip.h"

// The LED first, so that a hang taking the block out of reset is a steady
// LED, not a dark one.
void board_init(void) {
    led_init();
    sha_chip_init();
}

int board_hash(const uint8_t *src, uint32_t len, uint8_t *dst) { return sha_hw(src, len, dst); }

void board_case(uint32_t i, const struct outcome *o) {
    (void)i;
    (void)o;
}

void board_report(uint32_t ok, uint32_t failed_cases) {
    (void)failed_cases;
    led_verdict(ok);
}

void board_fault(uint32_t step, uint32_t cause) {
    (void)step;
    (void)cause;
    led_fault();
}
