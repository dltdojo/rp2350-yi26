// SPDX-License-Identifier: Apache-2.0
// vk26-alice-1 — what differs between the chip and the RTL: where the TRNG's
// words come from, who answers HASH, and how a stream's result is told.
#pragma once
#include <stdint.h>

void board_init(void);
// `n` words from the TRNG; 0 if it gave nothing within its timeout.
int board_trng(uint32_t *words, uint32_t n);
// HASH: SHA-256 of `len` bytes at `src` (a multiple of 64, word-aligned), 32
// bytes to `dst` — the chip's SHA-256 block on the chip, tools/hazard3/
// harness/sha256.c on the RTL. 0 if the block reported an error.
int board_hash(const uint8_t *src, uint32_t len, uint8_t *dst);
// One stream run: its 4096 samples packed 32 to a word, the code the kernel
// halted with, the code seam.py gives it (0xffffffff for the TRNG's, which
// nothing computed ahead), minstret, and the digests the kernel wrote, one
// per window that passed.
void board_stream(uint32_t round, uint32_t s, const char *name, const uint32_t *bits, uint32_t code,
                  uint32_t want, uint32_t instret, const uint8_t (*digest)[32], uint32_t ndigests);
// Every stream run and as it should be. On the RTL, the end; on the chip, a
// pause, and the streams again with a new draw from the TRNG.
void board_round(uint32_t round, uint32_t streams);
// A check failed: 1 the kernel's bytes are not kernel.sha256's, 2 it did not
// halt with the code it should, or trapped other than by HASH or a halt, or
// called HASH with arguments the model refuses, 3 minstret is not the RTL's
// count for its code, 4 a digest is not SHA-256 of its window or another byte
// of the region changed. (5 to 9 are speak.h's, the clocks' and USB's.) 10
// the TRNG gave nothing.
__attribute__((noreturn)) void board_fail(uint32_t check, uint32_t got);
__attribute__((noreturn)) void board_fault(uint32_t step, uint32_t cause);
