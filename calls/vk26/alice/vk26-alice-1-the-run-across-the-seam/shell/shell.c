// SPDX-License-Identifier: Apache-2.0
//
// vk26-alice-1 — the shell: six streams of 4096 samples, each judged by
// proof/Seam.lean's kernel in User mode under tools/hazard3/harness, forever
// on the chip, once on the RTL.
//
//   0     the TRNG: 128 words from it, each split into 32 samples
//   1-5   gen.py's FIXED: seam.py's streams, the run across the seam (11 + 10
//         ones, which must stop the kernel at window 2) and its control (10 +
//         10, which must not), and one stream for each other halt code
//
// For each: the 64 KiB region zeroed, kernel.bin's 552 bytes at its start
// (checked against kernel.sha256), sample i as a word, 0 or 1, at 0x400 + 4i;
// the region hashed. Then the kernel runs, the shell answering its HASH calls
// with board_hash, the arguments checked as the model checks them
// (hashcall.h). When it halts, the checks board.h numbers:
//
//   1 the kernel's bytes were kernel.sha256's
//   2 it halted with a code 0 to 4, seam.py's for a fixed stream, and called
//     HASH once for each window before the stop
//   3 minstret is the RTL's count for that code (gen.py)
//   4 each digest at 0x4400 + 32w is SHA-256 of window w — gen.py's hashlib
//     digest for a fixed stream, board_hash's of the window for the TRNG's —
//     and with those cleared the region hashes as it did before the run
//
// The TRNG's code is not checked against anything: no reference saw its
// samples before the kernel did. The page does, from the samples the chip
// sends (board_chip.c).
//
// A step counter is written before each step, for a trap in the shell itself
// to be named.

#include <stdint.h>

#ifndef REGION_SIZE
#define REGION_SIZE 0x10000u
#endif
#include "board.h"
#include "expect.h"
#include "hashcall.h"
#include "sha256.h"

#define csrr(name) ({ uint32_t v; __asm__ volatile ("csrr %0, " #name : "=r"(v)); v; })
#define csrw(name, v) __asm__ volatile ("csrw " #name ", %0" :: "r"(v))
#define SAMPLES  0x400u
#define DIGESTS  0x4400u
#define WINDOWS  4u
#define WINDOW   4096u          // bytes: 1024 samples of a word each
#define NSTREAMS (1u + NFIXED)
#define TRNG_WANT 0xffffffffu

extern void enter_payload(void) __attribute__((noreturn));

static volatile uint32_t step;
static uint32_t round, si, kernel_ok, hash_ok, calls;
static uint32_t bits[WORDS];
static uint8_t before[32], digest[WINDOWS][32];

static int same(const volatile uint8_t *a, const uint8_t *b, uint32_t n) {
    for (uint32_t i = 0; i < n; i++)
        if (a[i] != b[i]) return 0;
    return 1;
}

__attribute__((noreturn)) static void next_stream(void) {
    step = 2;
    if (si == 0) {
        if (!board_trng(bits, WORDS)) board_fail(10, round);
    } else {
        for (uint32_t k = 0; k < WORDS; k++) bits[k] = FIXED[si - 1].bits[k];
    }

    step = 3;
    volatile uint32_t *w = (volatile uint32_t *)REGION;
    for (uint32_t i = 0; i < REGION_SIZE / 4; i++) w[i] = 0;
    volatile uint8_t *r = (volatile uint8_t *)REGION;
    for (uint32_t i = 0; i < KERNEL_LEN; i++) r[i] = KERNEL[i];
    for (uint32_t i = 0; i < 32 * WORDS; i++) w[SAMPLES / 4 + i] = (bits[i / 32] >> (i % 32)) & 1u;

    step = 4;
    uint8_t d[32];
    sha256((const uint8_t *)REGION, KERNEL_LEN, d);
    kernel_ok = same(d, KERNEL_SHA, 32);
    hash_ok = board_hash((const uint8_t *)REGION, REGION_SIZE, before);
    calls = 0;
    enter_payload();
}

void shell_main(void) {
    step = 1;
    __asm__ volatile ("csrwi mcountinhibit, 4");   // mcycle runs; the harness takes the counters over later
    board_init();
    round = 0;
    si = 0;
    next_stream();
}

// Every trap: the kernel's ecall, a kernel fault, or the shell's own.
void handle(uint32_t *x) {
    uint32_t cause = csrr(mcause), instret = csrr(minstret);
    if (((csrr(mstatus) >> 11) & 3) == 3) board_fault(step, cause);
    __asm__ volatile ("csrwi mcountinhibit, 4");   // the harness held mcycle too; the TRNG's wait needs it

    step = 5;
    if (cause == 8 && x[5] == 0) {
        if (!hash_args_ok(x[10], x[11], x[12])) board_fail(2, x[12]);
        hash_ok &= board_hash((const uint8_t *)x[10], x[11], (uint8_t *)x[12]);
        calls++;
        csrw(mepc, csrr(mepc) + 4);
        return;
    }
    if (cause != 8 || x[5] != 1) board_fail(2, cause);

    step = 6;
    uint32_t code = x[10];
    uint32_t want = si ? FIXED[si - 1].want : TRNG_WANT;
    uint32_t passed = code == 0 ? WINDOWS : code - 1;
    if (!kernel_ok) board_fail(1, si);
    if (code > WINDOWS || (si && code != want) || calls != passed) board_fail(2, code);
    if (instret != INSTRET[code]) board_fail(3, instret);

    step = 7;
    volatile uint8_t *r = (volatile uint8_t *)REGION;
    int ok = hash_ok;
    for (uint32_t k = 0; k < passed; k++) {
        uint8_t want_d[32];
        if (si) {
            for (uint32_t i = 0; i < 32; i++) want_d[i] = FIXED[si - 1].digest[k][i];
        } else {
            ok &= board_hash((const uint8_t *)REGION + SAMPLES + WINDOW * k, WINDOW, want_d);
        }
        ok &= same(r + DIGESTS + 32 * k, want_d, 32);
        for (uint32_t i = 0; i < 32; i++) {
            digest[k][i] = r[DIGESTS + 32 * k + i];
            r[DIGESTS + 32 * k + i] = 0;
        }
    }
    uint8_t d[32];
    ok &= board_hash((const uint8_t *)REGION, REGION_SIZE, d) && same(d, before, 32);
    if (!ok) board_fail(4, si);

    step = 8;
    board_stream(round, si, si ? FIXED[si - 1].name : "trng", bits, code, want, instret,
                 (const uint8_t (*)[32])digest, passed);
    si++;
    if (si == NSTREAMS) {
        board_round(round, NSTREAMS);
        round++;
        si = 0;
    }
    next_stream();
}
