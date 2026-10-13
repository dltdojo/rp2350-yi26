// SPDX-License-Identifier: Apache-2.0
//
// vk26-alice-2 — the shell: five streams of 2048 samples, each judged by
// proof/Trust.lean's kernel in User mode under tools/hazard3/harness, forever
// on the chip, once on the RTL.
//
//   0     the TRNG: 64 words from it, each split into 32 samples
//   1-4   gen.py's FIXED: trust.py's streams. The first, fair, is run with
//         HASH's answer to the KAT spoiled — one bit of its first byte
//         flipped — so the kernel must stop with 2 before it reads a sample;
//         then the run across the start-up window's edge (3), its control
//         (0), and a source stuck from the start (1)
//
// For each: the 64 KiB region zeroed, kernel.bin's 448 bytes at its start
// (checked against kernel.sha256), the KAT's 64-byte message at 0x300 and
// hashlib's SHA-256 of it at 0x340 (gen.py), sample i as a word, 0 or 1, at
// 0x400 + 4i; the region hashed. The kernel runs; the shell answers its HASH
// calls with board_hash, the arguments checked as the model checks them
// (hashcall.h). When it halts, the checks board.h numbers:
//
//   1 the kernel's bytes were kernel.sha256's
//   2 the code is trust.py's for a fixed stream, 0 to 3 for the TRNG's, 2
//     exactly when the KAT's answer was spoiled; HASH called twice for 0,
//     once otherwise
//   3 minstret is the RTL's count for that code (gen.py)
//   4 the 32 bytes at the KAT's scratch are what HASH answered, and, unless
//     spoiled, hashlib's digest; with 0, the output is SHA-256 of window 1 —
//     gen.py's hashlib digest for a fixed stream, board_hash's for the TRNG's;
//     and with those two cleared the region hashes as it did before the run
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
#define KAT_AT   0x300u
#define WANT_AT  0x340u
#define GOT_AT   0x360u
#define SAMPLES  0x400u
#define OUTPUT   0x2400u
#define WINDOW   4096u          // bytes: 1024 samples of a word each
#define NSTREAMS (1u + NFIXED)
#define TRNG_WANT 0xffffffffu

extern void enter_payload(void) __attribute__((noreturn));

static volatile uint32_t step;
static uint32_t round, si, kernel_ok, hash_ok, calls, spoil;
static uint32_t bits[WORDS];
static uint8_t before[32], kat[32], output[32];

static int same(const volatile uint8_t *a, const uint8_t *b, uint32_t n) {
    for (uint32_t i = 0; i < n; i++)
        if (a[i] != b[i]) return 0;
    return 1;
}

__attribute__((noreturn)) static void next_stream(void) {
    step = 2;
    if (si == 0) {
        if (!board_trng(bits, WORDS)) board_fail(10, round);
        spoil = 0;
    } else {
        for (uint32_t k = 0; k < WORDS; k++) bits[k] = FIXED[si - 1].bits[k];
        spoil = FIXED[si - 1].spoil;
    }

    step = 3;
    volatile uint32_t *w = (volatile uint32_t *)REGION;
    for (uint32_t i = 0; i < REGION_SIZE / 4; i++) w[i] = 0;
    volatile uint8_t *r = (volatile uint8_t *)REGION;
    for (uint32_t i = 0; i < KERNEL_LEN; i++) r[i] = KERNEL[i];
    for (uint32_t i = 0; i < 64; i++) r[KAT_AT + i] = KAT_MSG[i];
    for (uint32_t i = 0; i < 32; i++) r[WANT_AT + i] = KAT_WANT[i];
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
        uint8_t *dst = (uint8_t *)x[12];
        hash_ok &= board_hash((const uint8_t *)x[10], x[11], dst);
        if (calls == 0) {
            if (spoil) dst[0] ^= 1;   // the hash the kernel is about to test, made wrong
            for (uint32_t i = 0; i < 32; i++) kat[i] = dst[i];
        }
        calls++;
        csrw(mepc, csrr(mepc) + 4);
        return;
    }
    if (cause != 8 || x[5] != 1) board_fail(2, cause);

    step = 6;
    uint32_t code = x[10];
    uint32_t want = si ? FIXED[si - 1].want : TRNG_WANT;
    if (!kernel_ok) board_fail(1, si);
    if (code > 3 || (si && code != want) || (code == 2) != (spoil != 0) || calls != (code == 0 ? 2u : 1u))
        board_fail(2, code);
    if (instret != INSTRET[code]) board_fail(3, instret);

    step = 7;
    volatile uint8_t *r = (volatile uint8_t *)REGION;
    int ok = hash_ok && same(r + GOT_AT, kat, 32) && (spoil || same(r + GOT_AT, KAT_WANT, 32));
    for (uint32_t i = 0; i < 32; i++) r[GOT_AT + i] = 0;
    if (code == 0) {
        uint8_t want_d[32];
        if (si) {
            for (uint32_t i = 0; i < 32; i++) want_d[i] = FIXED[si - 1].digest[i];
        } else {
            ok &= board_hash((const uint8_t *)REGION + SAMPLES + WINDOW, WINDOW, want_d);
        }
        ok &= same(r + OUTPUT, want_d, 32);
        for (uint32_t i = 0; i < 32; i++) {
            output[i] = r[OUTPUT + i];
            r[OUTPUT + i] = 0;
        }
    }
    uint8_t d[32];
    ok &= board_hash((const uint8_t *)REGION, REGION_SIZE, d) && same(d, before, 32);
    if (!ok) board_fail(4, si);

    step = 8;
    board_stream(round, si, si ? FIXED[si - 1].name : "trng", bits, code, want, instret, spoil, kat,
                 code == 0 ? output : 0);
    si++;
    if (si == NSTREAMS) {
        board_round(round, NSTREAMS);
        round++;
        si = 0;
    }
    next_stream();
}
