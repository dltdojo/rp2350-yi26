// SPDX-License-Identifier: Apache-2.0
//
// exp225 — the shell: Rule 30, forever, a life at a time, each life proved.
//
// A round: the 64 KiB region zeroed, kernel.bin's 76 bytes at its start
// (checked against kernel.sha256), the seed at 0x100. The kernel runs in User
// mode under tools/hazard3/harness and, by proof/Life.lean's `lives`, halts
// with 0 after exactly 3079 instructions with 256 generations from 0x200.
// The shell checks what it can see of that:
//   1 the kernel's bytes are kernel.sha256's
//   2 it halted (ecall, t0 = 1) with 0
//   3 minstret is the RTL's count, which does not depend on the seed
//   4 the first life — from one live cell — is rule30.py's, by SHA-256
// and then plays the life: the centre cell of each generation on the LED.
// The last generation is the next life's seed, so it never ends, and every
// beat of it was written by the proved bytes.
//
// A step counter is written before each step, for the RTL build to name the
// step a trap came from.

#include <stdint.h>

#include "board.h"
#include "expect.h"
#include "sha256.h"

#define csrr(name) ({ uint32_t v; __asm__ volatile ("csrr %0, " #name : "=r"(v)); v; })
#define REGION_SIZE 0x10000u
#define SEED_OFF 0x100u
#define HIST_OFF 0x200u

extern void enter_payload(void) __attribute__((noreturn));

static volatile uint32_t step;
static uint32_t seed, round, kernel_ok;
static uint32_t life[N];

static int same(const uint8_t *a, const uint8_t *b, uint32_t n) {
    for (uint32_t i = 0; i < n; i++)
        if (a[i] != b[i]) return 0;
    return 1;
}

__attribute__((noreturn)) static void next_round(void) {
    step = 2;
    volatile uint32_t *w = (volatile uint32_t *)REGION;
    for (uint32_t i = 0; i < REGION_SIZE / 4; i++) w[i] = 0;
    uint8_t *r = (uint8_t *)REGION;
    for (uint32_t i = 0; i < KERNEL_LEN; i++) r[i] = KERNEL[i];
    w[SEED_OFF / 4] = seed;

    step = 3;
    uint8_t d[32];
    sha256(r, KERNEL_LEN, d);
    kernel_ok = same(d, KERNEL_SHA, 32);
    enter_payload();
}

void shell_main(void) {
    step = 1;
    __asm__ volatile ("csrwi mcountinhibit, 4");   // mcycle runs; the harness takes the counters over later
    board_init();
    seed = SEED0;
    round = 0;
    next_round();
}

// Every trap: the payload's ecall, a payload fault, or the shell's own.
void handle(uint32_t *x) {
    uint32_t cause = csrr(mcause), instret = csrr(minstret);
    if (((csrr(mstatus) >> 11) & 3) == 3) board_fault(step, cause);
    __asm__ volatile ("csrwi mcountinhibit, 4");   // the harness held mcycle too; the LED's beat needs it

    step = 4;
    if (!kernel_ok) board_fail(1, 0);
    if (cause != 8 || x[5] != 1 || x[10] != 0) board_fail(2, cause == 8 ? x[10] : cause);
    if (instret != INSTRET) board_fail(3, instret);
    const uint32_t *h = (const uint32_t *)(REGION + HIST_OFF);
    if (round == 0) {
        uint8_t d[32];
        sha256((const uint8_t *)h, 4 * N, d);
        if (!same(d, HIST_SHA, 32)) board_fail(4, h[0]);
    }
    for (uint32_t g = 0; g < N; g++) life[g] = h[g];

    step = 5;
    board_play(life, round, instret);
    seed = life[N - 1];
    round++;
    next_round();
}
