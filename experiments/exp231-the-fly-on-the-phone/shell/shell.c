// SPDX-License-Identifier: Apache-2.0
//
// exp231 — the shell: exp225's life and exp230's fly, a round at a time, two
// proved kernels one after the other in the same 64 KiB region, each in User
// mode under tools/hazard3/harness.
//
// The life: the region zeroed, exp225's kernel.bin at its start (checked
// against its hash), the seed at 0x100. By exp225's `lives` it halts with 0
// after 3079 instructions, the 256 generations from 0x200. Checks 1 to 4 are
// exp225's, as its shell makes them.
//
// The fly: the region zeroed again, exp230's kernel.bin at its start (checked
// against its hash), and at 0x200 the 257 frames it watches — the seed, then
// the 256 generations. By exp230's `detects` it halts with 0 after 70924
// instructions, each step's two counts from 0x800 and the totals at 0x100.
// Every frame is Rule 30 of the one before, so by `watches_life` no step is
// seen moving down more than up. The shell checks what it can see of that:
//   10 the fly's kernel bytes are its hash's
//   11 it halted (ecall, t0 = 1) with 0
//   12 minstret is the RTL's count, which does not depend on the frames
//   13 the first round's steps and totals are fly.py's, by SHA-256
//   14 no step is seen moving down more than up — watches_life, on silicon
// and then shows the round. The last generation is the next round's seed.
//
// A step counter is written before each step, for the RTL build to name the
// step a trap came from.

#include <stdint.h>

#include "board.h"
#include "expect.h"
#include "fly.h"
#include "sha256.h"

#define csrr(name) ({ uint32_t v; __asm__ volatile ("csrr %0, " #name : "=r"(v)); v; })
#define REGION_SIZE 0x10000u
#define SEED_OFF   0x100u
#define HIST_OFF   0x200u
#define UP_OFF     0x100u
#define DOWN_OFF   0x104u
#define FRAMES_OFF 0x200u
#define STEPS_OFF  0x800u

extern void enter_payload(void) __attribute__((noreturn));

static volatile uint32_t step;
static uint32_t phase, kernel_ok;   // phase 0 the life, 1 the fly
static struct round r;

static int same(const uint8_t *a, const uint8_t *b, uint32_t n) {
    for (uint32_t i = 0; i < n; i++)
        if (a[i] != b[i]) return 0;
    return 1;
}

// The region zeroed, a kernel at its start, and whether its bytes are its hash's.
static void load(const uint8_t *kernel, uint32_t len, const uint8_t *sha) {
    volatile uint32_t *w = (volatile uint32_t *)REGION;
    for (uint32_t i = 0; i < REGION_SIZE / 4; i++) w[i] = 0;
    uint8_t *b = (uint8_t *)REGION;
    for (uint32_t i = 0; i < len; i++) b[i] = kernel[i];
    uint8_t d[32];
    sha256(b, len, d);
    kernel_ok = same(d, sha, 32);
}

__attribute__((noreturn)) static void the_life(void) {
    step = 2;
    phase = 0;
    load(KERNEL, KERNEL_LEN, KERNEL_SHA);
    ((volatile uint32_t *)REGION)[SEED_OFF / 4] = r.seed;
    step = 3;
    enter_payload();
}

__attribute__((noreturn)) static void the_fly(void) {
    step = 6;
    phase = 1;
    load(FLY, FLY_LEN, FLY_SHA);
    volatile uint32_t *w = (volatile uint32_t *)REGION;
    w[FRAMES_OFF / 4] = r.seed;
    for (uint32_t g = 0; g < N; g++) w[FRAMES_OFF / 4 + 1 + g] = r.life[g];
    step = 7;
    enter_payload();
}

void shell_main(void) {
    step = 1;
    __asm__ volatile ("csrwi mcountinhibit, 4");   // mcycle runs; the harness takes the counters over later
    board_init();
    r.seed = SEED0;
    r.round = 0;
    the_life();
}

// Every trap: a payload's ecall, a payload fault, or the shell's own.
void handle(uint32_t *x) {
    uint32_t cause = csrr(mcause), instret = csrr(minstret);
    if (((csrr(mstatus) >> 11) & 3) == 3) board_fault(step, cause);
    __asm__ volatile ("csrwi mcountinhibit, 4");   // the harness held mcycle too; the LED's beat needs it
    const uint32_t *w = (const uint32_t *)REGION;
    uint8_t d[32];

    if (phase == 0) {
        step = 4;
        if (!kernel_ok) board_fail(1, 0);
        if (cause != 8 || x[5] != 1 || x[10] != 0) board_fail(2, cause == 8 ? x[10] : cause);
        if (instret != INSTRET) board_fail(3, instret);
        if (r.round == 0) {
            sha256((const uint8_t *)(w + HIST_OFF / 4), 4 * N, d);
            if (!same(d, HIST_SHA, 32)) board_fail(4, w[HIST_OFF / 4]);
        }
        for (uint32_t g = 0; g < N; g++) r.life[g] = w[HIST_OFF / 4 + g];
        r.instret = instret;
        the_fly();
    }

    step = 8;
    if (!kernel_ok) board_fail(10, 0);
    if (cause != 8 || x[5] != 1 || x[10] != 0) board_fail(11, cause == 8 ? x[10] : cause);
    if (instret != FLY_INSTRET) board_fail(12, instret);
    for (uint32_t i = 0; i < 2 * N; i++) r.steps[i] = w[STEPS_OFF / 4 + i];
    r.up = w[UP_OFF / 4];
    r.down = w[DOWN_OFF / 4];
    r.fly_instret = instret;
    if (r.round == 0) {
        sha256((const uint8_t *)r.steps, 8 * N, d);
        if (!same(d, FLY_STEPS_SHA, 32) || r.up != FLY_UP0 || r.down != FLY_DOWN0) board_fail(13, r.up);
    }
    for (uint32_t g = 0; g < N; g++)
        if (r.steps[2 * g + 1] > r.steps[2 * g]) board_fail(14, g);

    step = 5;
    board_play(&r);
    r.seed = r.life[N - 1];
    r.round++;
    the_life();
}
