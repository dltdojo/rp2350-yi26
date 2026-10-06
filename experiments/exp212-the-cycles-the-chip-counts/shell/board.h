// SPDX-License-Identifier: Apache-2.0
// exp212 — what differs between the chip and the RTL: how HASH is computed,
// and how a result is told.
#pragma once
#include <stdint.h>
#include "expect.h"
#include "verdict.h"

void board_init(void);                                   // the LED on: alive
// HASH: SHA-256 of len bytes at src (len a multiple of 64, src word-aligned),
// 32 bytes to dst. Returns 0 if the hashing hardware reported an error.
int board_hash(const uint8_t *src, uint32_t len, uint8_t *dst);
void board_run(uint32_t i, const struct result *r, uint32_t instret);   // each run, as it ends
__attribute__((noreturn)) void board_report(uint32_t verdict);         // verdict.h's answer
__attribute__((noreturn)) void board_fault(uint32_t step, uint32_t cause);
