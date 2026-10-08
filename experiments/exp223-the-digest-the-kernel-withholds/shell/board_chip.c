// SPDX-License-Identifier: Apache-2.0
//
// exp223 — the Pico 2: the TRNG for real (tools/hazard3/shell/trng.h), the
// chip's SHA-256 block to hold the kernel's digest against
// (tools/hazard3/shell/sha_chip.h, exp210's), and the verdict on the LED
// (led.h): slow blinking for ok, a count of flashes for anything else.

#include "board.h"
#include "led.h"
#include "trng.h"
#include "sha_chip.h"

void board_init(void) {
    led_init();
    sha_chip_init();
}

int board_sha(const uint8_t *src, uint32_t len, uint8_t *dst) { return sha_hw(src, len, dst); }

#include "report_chip.h"
