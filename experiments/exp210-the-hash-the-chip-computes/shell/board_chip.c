// SPDX-License-Identifier: Apache-2.0
//
// exp210 — the Pico 2: HASH on the SHA-256 block (sha_hw.h), and the verdict
// on the LED, slow or fast (tools/hazard3/shell/led.h). Nothing per case
// leaves the chip; the RTL build prints that.

#include "board.h"
#include "led.h"

#define SHA256_BASE  0x400f8000u
#define RESET_SHA256 (1u << 17)

static uint32_t sha_rd(uint32_t off) { return REG(SHA256_BASE + off); }
static void sha_wr(uint32_t off, uint32_t v) { REG(SHA256_BASE + off) = v; }

#include "sha_hw.h"

// The LED first, so that a hang taking the block out of reset is a steady
// LED, not a dark one.
void board_init(void) {
    led_init();
    REG(RESETS_RESET_CLR) = RESET_SHA256;
    while (!(REG(RESETS_RESET_DONE) & RESET_SHA256)) {}
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
