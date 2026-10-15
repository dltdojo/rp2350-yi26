// SPDX-License-Identifier: Apache-2.0
// vk26-alice-5 — what differs between the chip and the RTL: where the TRNG's
// words come from, who answers HASH and HASHB, and how a run is told.
#pragma once
#include <stdint.h>

// Blocks a Generate returns: gen.py's M, which shell.c holds this to.
#define NBLOCKS 4

void board_init(void);
// `n` words from the TRNG; 0 if it gave nothing within its timeout.
int board_trng(uint32_t *words, uint32_t n);
// HASH (vk26-alice-2's kernel: a multiple of 64 bytes, word-aligned) and
// HASHB (the Instantiate kernel's and vk26-alice-4's: any length, anywhere):
// SHA-256 of `len` bytes at `src` to `dst`. The chip's SHA-256 block on the
// chip, tools/hazard3/harness/sha256.c on the RTL. 0 if the block reported an
// error.
int board_hash(const uint8_t *src, uint32_t len, uint8_t *dst);
int board_hashb(const uint8_t *src, uint32_t len, uint8_t *dst);
// One NIST case: its seed material (`s` bytes), V and C as the Instantiate
// kernel left them, the second Generate's M blocks, and minstret and mcycle
// of its three runs (Instantiate, Generate, Generate), six words.
void board_nist(uint32_t round, uint32_t i, const char *name, const uint8_t *seed, uint32_t s, const uint8_t *v,
                const uint8_t *c, const uint8_t *blocks, const uint32_t *runs);
// One chain from the TRNG: its 2048 samples packed 32 to a word, whether the
// shell spoiled HASH's answer to the KAT, that answer as vk26-alice-2's kernel
// saw it, the code it halted with, its minstret and mcycle; and with code 0
// only, its digest, V and C, the M blocks, and minstret and mcycle of the
// Instantiate kernel and of Generate (four words). The nonce is the round.
void board_chain(uint32_t round, uint32_t s, const uint32_t *bits, uint32_t spoil, const uint8_t *kat, uint32_t code,
                 const uint32_t *trust, const uint8_t *digest, const uint8_t *v, const uint8_t *c,
                 const uint8_t *blocks, const uint32_t *runs);
// Every case and both chains as they should be. On the RTL, the end; on the
// chip, a pause, and all of it again, the chains with a new draw.
void board_round(uint32_t round, uint32_t cases);
// A check failed: 1 a kernel's bytes are not its kernel.sha256's (got: 0
// alice-2's, 1 Instantiate, 2 alice-4's), 2 a kernel did not halt as it
// should (the NIST runs with 0; alice-2's with 2 exactly when the KAT's
// answer was spoiled, never 2 otherwise; after it, the Instantiate kernel and
// Generate with 0), called HASH the wrong number of times or with arguments
// the model refuses, or trapped some other way, 3 minstret is not the RTL's,
// 4 a NIST case's state after Instantiate is not seed.py's or its second
// Generate's bits are not NIST's, or alice-2's KAT scratch is not what HASH
// answered or its digest not SHA-256 of window 1. (5 to 9 are speak.h's.)
// 10 the TRNG gave nothing.
__attribute__((noreturn)) void board_fail(uint32_t check, uint32_t got);
__attribute__((noreturn)) void board_fault(uint32_t step, uint32_t cause);
