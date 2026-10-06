// SPDX-License-Identifier: Apache-2.0
// exp211 — what differs between the chip and the RTL: how HASH is computed,
// where the flash is, how the window is offered, and how a result is told.
#pragma once
#include <stdint.h>
#include "counter.h"

// How a boot ended. OUT_SIGNED is the only one in which a signature exists.
enum {
    OUT_SIGNED = 0,      // leaf signed, and the verifier accepted it
    OUT_EXHAUSTED,       // every leaf used: refused
    OUT_CORRUPT,         // the counter holds what this code never writes: refused
    OUT_UNWRITTEN,       // the claim did not read back: refused, nothing signed
    OUT_KERNEL,          // a kernel's bytes in SRAM are not its .sha256
    OUT_SIGN_FAILED,     // the signer did not halt with 0
    OUT_REJECTED,        // the verifier did not accept the signature
};

void board_init(void);                                   // the LED on: alive
// HASH: SHA-256 of len bytes at src (len a multiple of 64, src word-aligned),
// 32 bytes to dst. Returns 0 if the hashing hardware reported an error.
int board_hash(const uint8_t *src, uint32_t len, uint8_t *dst);
// Leaf `leaf` is claimed and not yet signed: the moment to cut the power, if
// this boot is one where a person does.
void board_window(uint32_t leaf);
__attribute__((noreturn)) void board_report(uint32_t outcome, const struct ctr *c, uint32_t leaf);
__attribute__((noreturn)) void board_fault(uint32_t step, uint32_t cause);
