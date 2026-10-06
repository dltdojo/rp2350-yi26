// SPDX-License-Identifier: Apache-2.0
//
// exp212 — the shell: first, seed 0's key generation once to warm the shell
// up (checked, not timed: see verdict.h); then for each seed, run exp213's
// key generator in User mode
// under tools/hazard3/harness/harness.S, then its signer on the tree the key
// generator just wrote; and once, the signer on another message. HASH calls
// are answered by board_hash (the SHA-256 block on the chip). harness.S holds
// mcycle and minstret everywhere but in the kernel, so what each run reads is
// the kernel's own time.
//
// Per run, every check:
//
//   1  the kernel's bytes in SRAM hash to exp213's .sha256 — the shell's own
//      SHA-256, in software, never the block
//   2  the kernel halted (ecall with t0 = 1) with code 0, not a fault
//   3  the whole region hashes to what the Lean model left there
//   4  minstret is what the RTL counted for the same kind of run
//   5  the hashing hardware never reported an error
//
// and its mcycle is kept. verdict.h turns them all into the LED's answer.
//
// A step counter is written before each step and never after, so a trap in
// the shell itself names the step that did not come back (on the RTL; on the
// chip a trap leaves the LED on).

#include <stdint.h>

#define REGION_SIZE 0x10000u   // REGION is the build's: 0x20070000 on the chip

#include "board.h"
#include "hashcall.h"
#include "sha256.h"

#define csrr(name) ({ uint32_t v; __asm__ volatile ("csrr %0, " #name : "=r"(v)); v; })
#define csrw(name, v) __asm__ volatile ("csrw " #name ", %0" :: "r"(v))

extern void enter_payload(void) __attribute__((noreturn));

static volatile uint32_t step;
static uint32_t current, kernel_ok, hash_ok, ran;
static struct result results[NRUNS];
static uint8_t tree[TREE_LEN];   // the last key generator's, for the signer after it

static int same(const uint8_t *a, const uint8_t *b, uint32_t n) {
    for (uint32_t i = 0; i < n; i++)
        if (a[i] != b[i]) return 0;
    return 1;
}

static void put(uint32_t at, const uint8_t *b, uint32_t n) {
    volatile uint8_t *r = (volatile uint8_t *)REGION;
    for (uint32_t i = 0; i < n; i++) r[at + i] = b[i];
}

static void fill(const struct fill *f, uint32_t n) {
    volatile uint8_t *r = (volatile uint8_t *)REGION;
    for (uint32_t k = 0; k < n; k++)
        for (uint32_t i = 0; i < f[k].len; i++) r[f[k].at + i] = 0xee;
}

// Build run `current`'s image in the region and enter it; after the last,
// report.
__attribute__((noreturn)) static void next_run(void) {
    if (current == NRUNS) board_report(verdict(RUNS, results, NRUNS, ran));
    const struct run *e = &RUNS[current];

    step = 2;
    volatile uint32_t *w = (volatile uint32_t *)REGION;
    for (uint32_t i = 0; i < REGION_SIZE / 4; i++) w[i] = 0;
    const uint8_t *k, *sha;
    uint32_t len;
    if (e->kind == KEYGEN || e->kind == KEYGEN_WARM) {
        k = KEYGEN_BIN, len = KEYGEN_LEN, sha = KEYGEN_SHA;
        put(0, k, len);
        put(K_SEED, SEED[e->seed], 32);
        fill(K_FILL, sizeof K_FILL / sizeof K_FILL[0]);
    } else {
        k = SIGN_BIN, len = SIGN_LEN, sha = SIGN_SHA;
        put(0, k, len);
        put(S_MSG, e->kind == SIGN ? MSG : OTHER, 32);
        ((volatile uint8_t *)REGION)[S_IDX] = LEAF;
        put(S_SEED, SEED[e->seed], 32);
        put(S_TREE, tree, TREE_LEN);
        fill(S_FILL, sizeof S_FILL / sizeof S_FILL[0]);
    }

    step = 3;
    uint8_t d[32];
    sha256((const uint8_t *)REGION, len, d);
    kernel_ok = same(d, sha, 32);
    hash_ok = 1;

    step = 4;
    enter_payload();
}

void shell_main(void) {
    step = 1;
    board_init();
    current = 0;
    next_run();
}

// Every trap: the payload's ecall, a payload fault, or the shell's own.
void handle(uint32_t *x) {
    uint32_t cause = csrr(mcause), instret = csrr(minstret), cycles = csrr(mcycle);
    if (((csrr(mstatus) >> 11) & 3) == 3) board_fault(step, cause);

    // HASH: back into the payload, as the model's syscall does.
    if (cause == 8 && x[5] == 0 && hash_args_ok(x[10], x[11], x[12])) {
        hash_ok &= board_hash((const uint8_t *)x[10], x[11], (uint8_t *)x[12]);
        csrw(mepc, csrr(mepc) + 4);
        return;
    }

    step = 5;
    const struct run *e = &RUNS[current];
    uint8_t d[32];
    sha256((const uint8_t *)REGION, REGION_SIZE, d);
    int halted = cause == 8 && x[5] == 1;
    int ok[6] = {0, kernel_ok, halted && x[10] == 0, same(d, e->region, 32), instret == e->instret, hash_ok};
    struct result *r = &results[current];
    r->failed = 0;
    r->cycles = cycles;
    for (uint32_t c = 1; c <= 5; c++)
        if (!ok[c]) r->failed = r->failed * 10 + c;
    if (e->kind == KEYGEN || e->kind == KEYGEN_WARM)
        for (uint32_t i = 0; i < TREE_LEN; i++) tree[i] = ((const uint8_t *)REGION)[K_TREE + i];
    ran++;
    board_run(current, r, instret);
    current++;
    next_run();
}
