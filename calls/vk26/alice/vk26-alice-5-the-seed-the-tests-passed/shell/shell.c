// SPDX-License-Identifier: Apache-2.0
//
// vk26-alice-5 — the shell: three proved kernels on one region, chained, the
// shell's only step between them putting the next kernel's bytes at the
// region's start (proof/Seed.lean's `restart`). Forever on the chip, once on
// the RTL. A round:
//
//   1. every NIST case of ../tools/cavp/Hash_DRBG_SHA256.txt: the Instantiate
//      kernel (kernel.bin) on the seed material, entropy ‖ nonce ‖
//      personalization, at 0x2400; then vk26-alice-4's Generate twice. The
//      second's bits are NIST's ReturnedBits
//   2. the chain, twice, on 2048 samples from the TRNG (64 words, 32 samples
//      each, as vk26-alice-2's shell takes them), the nonce the round:
//      vk26-alice-2's kernel (the KAT on HASH, the start-up window, the next
//      window, the digest of it to 0x2400); with 0, the Instantiate kernel on
//      what it left; then vk26-alice-4's Generate. The second time with
//      HASH's answer to the KAT spoiled, one bit of it, so that the chain
//      must stop at the first kernel with 2
//
// The shell answers HASH (alice-2's kernel) on board_hash and HASHB (the
// other two) on board_hashb, the arguments held to what the model accepts
// (hashcall.h). Before each kernel runs, its bytes in the region are checked
// against its kernel.sha256. The checks board.h numbers:
//
//   1 a kernel's bytes were its kernel.sha256's
//   2 every halt code as it must be
//   3 every minstret the RTL's (gen.py): the Instantiate kernel's one more in
//     the chain than alone, as the RTL counts the word after a halting ecall
//     when it is an instruction (alice-2's, left past the 244 bytes)
//   4 a NIST case's region 0x400..0x600 after Instantiate hashes to seed.py's,
//     and its second Generate's bits are NIST's; alice-2's KAT scratch holds
//     what HASH answered (hashlib's digest unless spoiled), and with 0 its
//     digest is SHA-256 of window 1 by board_hash
//
// What the chain's bits are for the TRNG's samples, the page and fixtures.py
// say, from the lines: there is nothing on the chip to compare them with.
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

_Static_assert(M == NBLOCKS, "gen.py's M is not board.h's NBLOCKS");

#define csrr(name) ({ uint32_t v; __asm__ volatile ("csrr %0, " #name : "=r"(v)); v; })
#define csrw(name, v) __asm__ volatile ("csrw " #name ", %0" :: "r"(v))
#define KAT_AT   0x300u
#define WANT_AT  0x340u
#define GOT_AT   0x360u
#define SAMPLES  0x400u
#define WINDOW   4096u
#define SEED     0x2400u
#define NONCE    0x2420u
#define PI       0x2480u
#define V_AT     0x440u
#define C_AT     0x480u
#define OUT      0x600u
#define WORDS    64u
#define NONCE_LEN 16u

enum { NIST_I, NIST_G1, NIST_G2, CHAIN_T, CHAIN_I, CHAIN_G };

extern void enter_payload(void) __attribute__((noreturn));

static volatile uint32_t step;
static uint32_t round, ci, si, stage, calls, spoil, code;
static uint32_t bits[WORDS], runs[6], trust[2];
static uint8_t v[55], c[55], blocks[32 * M], kat[32], digest[32];

static int same(const volatile uint8_t *a, const uint8_t *b, uint32_t n) {
    for (uint32_t i = 0; i < n; i++)
        if (a[i] != b[i]) return 0;
    return 1;
}

static void put_word(volatile uint8_t *r, uint32_t at, uint32_t x) {
    for (uint32_t k = 0; k < 4; k++) r[at + k] = (uint8_t)(x >> (8 * k));
}

// The shell's step between kernels: `len` bytes of code at the region's
// start, checked against their hash; nothing else touched.
static void load(const uint8_t *code_bytes, uint32_t len, const uint8_t *sha, uint32_t which) {
    volatile uint8_t *r = (volatile uint8_t *)REGION;
    for (uint32_t i = 0; i < len; i++) r[i] = code_bytes[i];
    uint8_t d[32];
    sha256((const uint8_t *)REGION, len, d);
    if (!same(d, sha, 32)) board_fail(1, which);
}

static void zero(void) {
    volatile uint32_t *w = (volatile uint32_t *)REGION;
    for (uint32_t i = 0; i < REGION_SIZE / 4; i++) w[i] = 0;
}

static void params(uint32_t s) {
    volatile uint8_t *r = (volatile uint8_t *)REGION;
    put_word(r, PI, M);
    put_word(r, PI + 4, INTERVAL);
    put_word(r, PI + 8, s);
}

__attribute__((noreturn)) static void next_case(void) {
    step = 2;
    const struct kcase *k = &CASES[ci];
    zero();
    load(KERNEL, KERNEL_LEN, KERNEL_SHA, 1);
    volatile uint8_t *r = (volatile uint8_t *)REGION;
    for (uint32_t i = 0; i < k->s; i++) r[SEED + i] = k->seed[i];
    params(k->s);
    stage = NIST_I;
    enter_payload();
}

__attribute__((noreturn)) static void next_chain(void) {
    step = 3;
    if (si == 0 && !board_trng(bits, WORDS)) board_fail(10, round);
    spoil = si;
    zero();
    load(TRUST, TRUST_LEN, TRUST_SHA, 0);
    volatile uint8_t *r = (volatile uint8_t *)REGION;
    volatile uint32_t *w = (volatile uint32_t *)REGION;
    for (uint32_t i = 0; i < 64; i++) r[KAT_AT + i] = KAT_MSG[i];
    for (uint32_t i = 0; i < 32; i++) r[WANT_AT + i] = KAT_WANT[i];
    for (uint32_t i = 0; i < 32 * WORDS; i++) w[SAMPLES / 4 + i] = (bits[i / 32] >> (i % 32)) & 1u;
    put_word(r, NONCE, round);
    params(32 + NONCE_LEN);
    calls = 0;
    stage = CHAIN_T;
    enter_payload();
}

void shell_main(void) {
    step = 1;
    __asm__ volatile ("csrwi mcountinhibit, 4");   // mcycle runs; the harness takes the counters over later
    board_init();
    round = 0;
    ci = 0;
    next_case();
}

static void keep(volatile uint8_t *r) {
    for (uint32_t i = 0; i < 55; i++) {
        v[i] = r[V_AT + i];
        c[i] = r[C_AT + i];
    }
}

// Every trap: a kernel's ecall, a kernel fault, or the shell's own.
void handle(uint32_t *x) {
    uint32_t cause = csrr(mcause), instret = csrr(minstret), cycles = csrr(mcycle);
    if (((csrr(mstatus) >> 11) & 3) == 3) board_fault(step, cause);
    __asm__ volatile ("csrwi mcountinhibit, 4");   // the harness held mcycle too; the TRNG's wait needs it

    step = 4;
    if (cause == 8 && x[5] == 0 && stage == CHAIN_T) {
        if (!hash_args_ok(x[10], x[11], x[12])) board_fail(2, x[12]);
        uint8_t *dst = (uint8_t *)x[12];
        if (!board_hash((const uint8_t *)x[10], x[11], dst)) board_fail(4, x[11]);
        if (calls == 0) {
            if (spoil) dst[0] ^= 1;   // the hash the kernel is about to test, made wrong
            for (uint32_t i = 0; i < 32; i++) kat[i] = dst[i];
        }
        calls++;
        csrw(mepc, csrr(mepc) + 4);
        return;
    }
    if (cause == 8 && x[5] == 2 && stage != CHAIN_T) {
        if (!hashb_args_ok(x[10], x[11], x[12]) || !board_hashb((const uint8_t *)x[10], x[11], (uint8_t *)x[12]))
            board_fail(2, x[11]);
        csrw(mepc, csrr(mepc) + 4);
        return;
    }
    if (cause != 8 || x[5] != 1) board_fail(2, cause);

    step = 5;
    volatile uint8_t *r = (volatile uint8_t *)REGION;
    uint8_t d[32];
    code = x[10];
    if (stage == CHAIN_T) {
        if (code > 3 || (code == 2) != (spoil != 0) || calls != (code == 0 ? 2u : 1u)) board_fail(2, code);
        if (instret != INSTRET_TRUST[code]) board_fail(3, instret);
        if (!same(r + GOT_AT, kat, 32) || (!spoil && !same(r + GOT_AT, KAT_WANT, 32))) board_fail(4, si);
        trust[0] = instret;
        trust[1] = cycles;
        if (code == 0) {
            if (!board_hash((const uint8_t *)REGION + SAMPLES + WINDOW, WINDOW, d) || !same(r + SEED, d, 32))
                board_fail(4, si);
            for (uint32_t i = 0; i < 32; i++) digest[i] = r[SEED + i];
            load(KERNEL, KERNEL_LEN, KERNEL_SHA, 1);
            stage = CHAIN_I;
            enter_payload();
        }
    } else {
        if (code != 0) board_fail(2, code);
        uint32_t n = stage == CHAIN_I ? 0 : stage == CHAIN_G ? 1 : stage - NIST_I;
        runs[2 * n] = instret;
        runs[2 * n + 1] = cycles;
        if (instret != (stage == NIST_I ? INSTRET_INST : stage == CHAIN_I ? INSTRET_INST_CHAIN : INSTRET_GEN))
            board_fail(3, instret);
        if (stage == NIST_I || stage == CHAIN_I) {
            if (stage == NIST_I && (!board_hash((const uint8_t *)REGION + 0x400, 0x200, d) || !same(d, CASES[ci].state, 32)))
                board_fail(4, ci);
            keep(r);
            load(DRBG, DRBG_LEN, DRBG_SHA, 2);
            stage++;
            enter_payload();
        }
        if (stage == NIST_G1) {
            stage = NIST_G2;
            enter_payload();
        }
        for (uint32_t i = 0; i < 32 * M; i++) blocks[i] = r[OUT + i];
        if (stage == NIST_G2 && !same(blocks, CASES[ci].want, 32 * M)) board_fail(4, ci);
    }

    step = 6;
    if (stage <= NIST_G2) {
        board_nist(round, ci, CASES[ci].name, CASES[ci].seed, CASES[ci].s, v, c, blocks, runs);
        if (++ci < NCASES) next_case();
        si = 0;
        next_chain();
    }
    board_chain(round, si, bits, spoil, kat, code, trust, code ? 0 : digest, v, c, blocks, runs);
    if (++si < 2) next_chain();
    board_round(round, NCASES);
    round++;
    ci = 0;
    next_case();
}
