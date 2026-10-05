// SPDX-License-Identifier: Apache-2.0
// exp210 — what differs between the chip and the RTL: how HASH is computed,
// and how a result is told.
#pragma once
#include <stdint.h>

// One case, as the shell found it.
struct outcome {
    uint32_t ok;         // every check passed: see shell.c
    uint32_t failed;     // the failed checks as decimal digits, ascending
    uint32_t a0, instret, cause;
};

void board_init(void);                                   // the LED on: alive
// HASH: SHA-256 of len bytes at src (len a multiple of 64, src word-aligned),
// 32 bytes to dst. Returns 0 if the hashing hardware reported an error.
int board_hash(const uint8_t *src, uint32_t len, uint8_t *dst);
void board_case(uint32_t i, const struct outcome *o);    // each case, as it ends
__attribute__((noreturn)) void board_report(uint32_t ok, uint32_t failed_cases);
__attribute__((noreturn)) void board_fault(uint32_t step, uint32_t cause);
