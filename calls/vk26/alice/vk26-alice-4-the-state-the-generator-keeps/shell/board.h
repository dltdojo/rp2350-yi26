// SPDX-License-Identifier: Apache-2.0
// vk26-alice-4 — what differs between the chip and the RTL: who answers the
// kernel's HASHB and hashes the region, and how a case's runs are told.
#pragma once
#include <stdint.h>

void board_init(void);
// SHA-256 of `len` bytes at `src` to `dst`: HASHB, any length and any start,
// for the kernel; and the region's first WINDOW bytes, for the shell. The
// chip's SHA-256 block on the chip, tools/hazard3/harness/sha256.c on the RTL.
int board_hash(const uint8_t *src, uint32_t len, uint8_t *dst);
int board_hashb(const uint8_t *src, uint32_t len, uint8_t *dst);
// One run of a case's three: n = 1 and 2 the Generates, 3 the reseed check.
// `code` the halt code, `counter` the word at 0x408 afterwards, minstret and
// mcycle; for a Generate, `blocks` its `nblocks` blocks at 0x600 and `v` V at
// 0x440 afterwards, 0 for the third run. Before the first, the state the
// shell put there: n = 0, `v` and `c` V and C, nothing else.
void board_state(uint32_t round, uint32_t i, const uint8_t *v, const uint8_t *c);
void board_run(uint32_t round, uint32_t i, uint32_t n, uint32_t code, uint32_t counter, uint32_t instret,
               uint32_t cycles, const uint8_t *blocks, uint32_t nblocks, const uint8_t *v);
// A case, every run as it should be.
void board_case(uint32_t round, uint32_t i, const char *name);
// Every case as it should be. On the RTL, the end; on the chip, a pause, and
// the cases again.
void board_round(uint32_t round, uint32_t cases);
// A check failed: 1 the kernel's bytes are not kernel.sha256's, 2 a run did
// not halt as it should (the Generates with 0, the third with 1, by HALT; a
// HASHB the model refuses counts as not halting), 3 minstret is not the RTL's
// count, 4 the second Generate's bits are not NIST's, or the region after it
// is not drbg.py's, or the third run changed it. (5 to 9 are speak.h's.)
__attribute__((noreturn)) void board_fail(uint32_t check, uint32_t got);
__attribute__((noreturn)) void board_fault(uint32_t step, uint32_t cause);
