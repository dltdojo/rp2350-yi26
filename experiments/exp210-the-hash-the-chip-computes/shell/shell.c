// SPDX-License-Identifier: Apache-2.0
//
// exp210 — the shell: run every case of exp204's and exp205's kernels in User
// mode under tools/hazard3/harness/harness.S, answer their HASH calls with
// board_hash (the SHA-256 block on the chip), and check each case against
// what the Lean model and the RTL did with it.
//
// Per case, every check is run:
//
//   1  the kernel's bytes in SRAM hash to its kernel.sha256 — the shell's own
//      SHA-256, in software, never the block being tested
//   2  the kernel halted: ecall with t0 = 1, not a fault
//   3  with the verdict the model gave (a0)
//   4  every byte of the region is what the model left there
//   5  minstret is what the RTL counted for the same image
//   6  the hashing hardware never reported an error
//
// The verdict — the one bit the LED gives — is every check of every case,
// and that every case ran.
//
// A step counter is written before each step and never after, so a trap in
// the shell itself names the step that did not come back (on the RTL; on the
// chip a trap leaves the LED on, which is all one bit can say).

#include <stdint.h>

#define REGION_SIZE 0x10000u   // REGION is the build's: 0x20070000 on the chip

#include "board.h"
#include "expect.h"
#include "hashcall.h"
#include "sha256.h"

#define csrr(name) ({ uint32_t v; __asm__ volatile ("csrr %0, " #name : "=r"(v)); v; })
#define csrw(name, v) __asm__ volatile ("csrw " #name ", %0" :: "r"(v))

extern void enter_payload(void) __attribute__((noreturn));

static volatile uint32_t step;
static uint32_t current, kernel_ok, hash_ok, failed_cases, ran;

static int same(const uint8_t *a, const uint8_t *b, uint32_t n) {
    for (uint32_t i = 0; i < n; i++)
        if (a[i] != b[i]) return 0;
    return 1;
}

// Put case `current` in the region and enter it; or, after the last, report.
__attribute__((noreturn)) static void next_case(void) {
    if (current == NCASES) board_report(failed_cases == 0 && ran == NCASES, failed_cases);
    const struct expect *e = &CASES[current];

    step = 2;
    volatile uint32_t *w = (volatile uint32_t *)REGION;
    for (uint32_t i = 0; i < REGION_SIZE / 4; i++) w[i] = 0;
    uint8_t *r = (uint8_t *)REGION;
    for (uint32_t p = e->in0; p < e->in1; p++)
        for (uint32_t j = 0; j < 64; j++) r[64 * CASE_IN[p].at + j] = BLOCK[CASE_IN[p].block][j];

    step = 3;
    uint8_t d[32];
    sha256(r, KERNEL_LEN[e->kernel], d);
    kernel_ok = same(d, KERNEL_SHA[e->kernel], 32);
    hash_ok = 1;

    step = 4;
    enter_payload();
}

void shell_main(void) {
    step = 1;
    board_init();
    current = 0;
    next_case();
}

// What the model left at region block n: CASE_OUT if the model changed it,
// else CASE_IN, else zeros. Both lists ascend, so each is walked once.
static int region_as_model_left(const struct expect *e) {
    const uint8_t *r = (const uint8_t *)REGION;
    uint32_t p = e->in0, q = e->out0;
    for (uint32_t n = 0; n < REGION_SIZE / 64; n++) {
        uint32_t b = 0;
        while (p < e->in1 && CASE_IN[p].at < n) p++;
        while (q < e->out1 && CASE_OUT[q].at < n) q++;
        if (q < e->out1 && CASE_OUT[q].at == n) b = CASE_OUT[q].block;
        else if (p < e->in1 && CASE_IN[p].at == n) b = CASE_IN[p].block;
        if (!same(r + 64 * n, BLOCK[b], 64)) return 0;
    }
    return 1;
}

// Every trap: the payload's ecall, a payload fault, or the shell's own.
void handle(uint32_t *x) {
    uint32_t cause = csrr(mcause), instret = csrr(minstret);
    if (((csrr(mstatus) >> 11) & 3) == 3) board_fault(step, cause);

    // HASH: back into the payload, as the model's syscall does.
    if (cause == 8 && x[5] == 0 && hash_args_ok(x[10], x[11], x[12])) {
        hash_ok &= board_hash((const uint8_t *)x[10], x[11], (uint8_t *)x[12]);
        csrw(mepc, csrr(mepc) + 4);
        return;
    }

    step = 5;
    const struct expect *e = &CASES[current];
    struct outcome o = {0};
    o.a0 = x[10];
    o.instret = instret;
    o.cause = cause;
    int halted = cause == 8 && x[5] == 1;
    int ok[7] = {0, kernel_ok, halted, halted && x[10] == e->a0, region_as_model_left(e),
                 instret == e->instret, hash_ok};
    o.ok = 1;
    for (uint32_t k = 1; k <= 6; k++)
        if (!ok[k]) {
            o.failed = o.failed * 10 + k;
            o.ok = 0;
        }
    failed_cases += !o.ok;
    ran++;
    board_case(current, &o);
    current++;
    next_case();
}
