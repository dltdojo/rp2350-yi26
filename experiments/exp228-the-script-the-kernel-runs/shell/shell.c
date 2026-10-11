// SPDX-License-Identifier: Apache-2.0
//
// exp228 — the shell: every hand case of cases.py, run by the proved kernel,
// forever, the shell answering its two calls.
//
// A case: the 64 KiB region zeroed, kernel.bin's 0x1400 bytes at its start (the
// kernel and its table, checked against kernel.sha256), then the case's script
// at SCRIPT with its length at SLEN and its initial stack in the slots from
// STACK with its depth at DEPTH — the layout proof/Script.lean's `Input`
// describes. The kernel runs in User mode under tools/hazard3/harness and, by
// `kernel_verdict`, halts with the specification's verdict, whatever the shell
// answers. The shell answers:
//
//   ecall t0 = 2   HASHB: SHA-256 of a1 bytes at a0, written at a2
//   ecall t0 = 3   CHECKSIG: BIP340 (bip340.c) of the 64 bytes at a1, as a
//                  signature of MSG under the 32-byte key at a0
//
// with the arguments checked as the model checks them (hashcall.h). When it
// halts the shell checks what it can see:
//   1 the kernel's bytes were kernel.sha256's
//   2 the exit code is script.py's verdict for the case, which the Lean model
//     gave too (gen.py)
//   3 minstret is the model's count plus the harness's four
//   4 it halted at all, and did not trap some other way — a call with
//     arguments the model refuses counts as such a trap
//
// A step counter is written before each step, for a trap in the shell itself
// to be named.

#include <stdint.h>

#ifndef REGION_SIZE
#define REGION_SIZE 0x10000u
#endif
#include "bip340.h"
#include "board.h"
#include "expect.h"
#include "hashcall.h"
#include "sha256.h"

#define csrr(name) ({ uint32_t v; __asm__ volatile ("csrr %0, " #name : "=r"(v)); v; })
#define csrw(name, v) __asm__ volatile ("csrw " #name ", %0" :: "r"(v))
#define SLEN 0x1400u
#define SCRIPT 0x1404u
#define DEPTH 0x1800u
#define STACK 0x1804u
#define SLOT 84u

extern void enter_payload(void) __attribute__((noreturn));

// hashcall.h's HASH (t0 = 0) is not one of this kernel's calls.
static int (*const unused_hash)(uint32_t, uint32_t, uint32_t) __attribute__((unused)) = hash_args_ok;

static volatile uint32_t step;
static uint32_t round, ci, kernel_ok, sigs, valid;

static int same(const uint8_t *a, const uint8_t *b, uint32_t n) {
    for (uint32_t i = 0; i < n; i++)
        if (a[i] != b[i]) return 0;
    return 1;
}

static void put_word(volatile uint8_t *r, uint32_t at, uint32_t v) {
    for (uint32_t k = 0; k < 4; k++) r[at + k] = (uint8_t)(v >> (8 * k));
}

__attribute__((noreturn)) static void next_case(void) {
    step = 2;
    const struct kcase *c = &CASES[ci];
    volatile uint32_t *w = (volatile uint32_t *)REGION;
    for (uint32_t i = 0; i < REGION_SIZE / 4; i++) w[i] = 0;
    volatile uint8_t *r = (volatile uint8_t *)REGION;
    for (uint32_t i = 0; i < KERNEL_LEN; i++) r[i] = KERNEL[i];
    put_word(r, SLEN, c->script_len);
    for (uint32_t i = 0; i < c->script_len; i++) r[SCRIPT + i] = SCRIPTS[c->script + i];
    put_word(r, DEPTH, c->depth);
    const uint8_t *e = ELEMS + c->elems;
    for (uint32_t k = 0; k < c->depth; k++) {
        uint32_t len = *e++;
        put_word(r, STACK + SLOT * k, len);
        for (uint32_t i = 0; i < len; i++) r[STACK + SLOT * k + 4 + i] = *e++;
    }

    step = 3;
    uint8_t d[32];
    sha256((const uint8_t *)REGION, KERNEL_LEN, d);
    kernel_ok = same(d, KERNEL_SHA, 32);
    sigs = valid = 0;
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

// Every trap: the kernel's ecall, a kernel fault, or the shell's own.
void handle(uint32_t *x) {
    uint32_t cause = csrr(mcause), instret = csrr(minstret);
    if (((csrr(mstatus) >> 11) & 3) == 3) board_fault(step, cause);
    __asm__ volatile ("csrwi mcountinhibit, 4");   // the harness held mcycle too; the LED's beat needs it

    step = 4;
    if (cause == 8 && x[5] == 2) {
        if (!hashb_args_ok(x[10], x[11], x[12])) board_fail(4, cause);
        sha256((const uint8_t *)x[10], x[11], (uint8_t *)x[12]);
        csrw(mepc, csrr(mepc) + 4);
        return;
    }
    if (cause == 8 && x[5] == 3) {
        if (!sig_args_ok(x[10], x[11])) board_fail(4, cause);
        sigs++;
        x[10] = bip340_verify((const uint8_t *)x[10], MSG, 32, (const uint8_t *)x[11]) ? 1 : 0;
        valid += x[10];
        csrw(mepc, csrr(mepc) + 4);
        return;
    }
    if (cause != 8 || x[5] != 1) board_fail(4, cause);

    step = 5;
    const struct kcase *c = &CASES[ci];
    board_case(round, ci, c->name, x[10], c->want, instret, sigs, valid);
    if (!kernel_ok) board_fail(1, ci);
    if (x[10] != c->want) board_fail(2, ci);
    if (instret != c->instret) board_fail(3, ci);
    ci++;
    if (ci == NCASES) {
        board_round(round, NCASES);
        round++;
        ci = 0;
    }
    next_case();
}
