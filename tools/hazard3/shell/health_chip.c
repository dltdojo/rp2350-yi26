// SPDX-License-Identifier: Apache-2.0
//
// tools/hazard3/shell — a health-test shell's board on the Pico 2: the TRNG for
// real (trng.h), the chip's SHA-256 block (sha_chip.h, exp210's) for board_sha,
// and the verdict on the LED (led.h, report_chip.h): slow blinking for ok, a
// count of flashes for anything else. board.h is the includer's: its struct
// result, its verdicts and the prototypes. exp223 wrote it, exp224 needed it
// second.

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
