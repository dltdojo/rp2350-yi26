// SPDX-License-Identifier: Apache-2.0
//
// tools/hazard3/shell — the SHA-256 block on the chip: sha_hw.h over volatile
// registers, and taking the block out of reset. Included by a shell's
// board_chip.c after led.h, so that the LED is already up when the reset is
// released: a hang there is a steady LED, not a dark one.
#pragma once
#include <stdint.h>
#include "led.h"

#define SHA256_BASE  0x400f8000u
#define RESET_SHA256 (1u << 17)

static uint32_t sha_rd(uint32_t off) { return REG(SHA256_BASE + off); }
static void sha_wr(uint32_t off, uint32_t v) { REG(SHA256_BASE + off) = v; }

#include "sha_hw.h"

static inline __attribute__((always_inline)) void sha_chip_init(void) {
    REG(RESETS_RESET_CLR) = RESET_SHA256;
    while (!(REG(RESETS_RESET_DONE) & RESET_SHA256)) {}
}
