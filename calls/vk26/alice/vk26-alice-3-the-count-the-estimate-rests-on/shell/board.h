// SPDX-License-Identifier: Apache-2.0
// vk26-alice-3 — what differs between the chip and the RTL: where the TRNG's
// words come from, who hashes the region, and how a stream's result is told.
#pragma once
#include <stdint.h>

void board_init(void);
// `n` words from the TRNG, its own tests on (the von Neumann balancer's
// output) or bypassed (the raw bits); 0 if it gave nothing within its timeout.
int board_trng(uint32_t *words, uint32_t n);
int board_trng_raw(uint32_t *words, uint32_t n);
// SHA-256 of `len` bytes, for the region before and after: the chip's
// SHA-256 block on the chip, tools/hazard3/harness/sha256.c on the RTL.
int board_hash(const uint8_t *src, uint32_t len, uint8_t *dst);
// One stream run: its 4096 samples as 1024 words (sample i is byte i % 4 of
// word i / 4), the 256 counts the kernel wrote and the largest, gen.py's
// largest for it (0xffffffff for the TRNG's), minstret and mcycle of the
// first run, and of the second, straight after it.
void board_stream(uint32_t round, uint32_t s, const char *name, const uint32_t *words, const uint32_t *counts,
                  uint32_t most, uint32_t want, uint32_t instret, uint32_t cycles, uint32_t again_instret,
                  uint32_t again_cycles);
// Every stream run and as it should be. On the RTL, the end; on the chip, a
// pause, and the streams again with new draws from the TRNG.
void board_round(uint32_t round, uint32_t streams);
// A check failed: 1 the kernel's bytes are not kernel.sha256's, 2 it did not
// halt with 0 (it called HASH, or trapped some other way), 3 minstret is not
// the RTL's count, 4 a count is not the shell's own count of the samples, the
// largest is not the largest of them or not gen.py's, or another byte of the
// region changed. (5 to 9 are speak.h's.) 10 a TRNG gave nothing.
__attribute__((noreturn)) void board_fail(uint32_t check, uint32_t got);
__attribute__((noreturn)) void board_fault(uint32_t step, uint32_t cause);
