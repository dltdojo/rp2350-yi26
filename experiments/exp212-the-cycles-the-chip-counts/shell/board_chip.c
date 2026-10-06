// SPDX-License-Identifier: Apache-2.0
//
// exp212 — the Pico 2: HASH on the SHA-256 block (tools/hazard3/shell/
// sha_chip.h), and the verdict on the LED: slow, double flash, or fast
// (led.h). Nothing per run leaves the chip; the RTL build prints that.

#include "board.h"
#include "led.h"
#include "sha_chip.h"

void board_init(void) {
    led_init();
    sha_chip_init();
}

int board_hash(const uint8_t *src, uint32_t len, uint8_t *dst) { return sha_hw(src, len, dst); }

void board_run(uint32_t i, const struct result *r, uint32_t instret) {
    (void)i;
    (void)r;
    (void)instret;
}

void board_report(uint32_t v) {
    if (v == DOUBLE) led_double();
    led_verdict(v == SLOW);
}

void board_fault(uint32_t step, uint32_t cause) {
    (void)step;
    (void)cause;
    led_fault();
}
