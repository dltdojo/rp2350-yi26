// SPDX-License-Identifier: Apache-2.0
//
// exp221 — the shell: two PIO blocks answer, and a proved RV32IM kernel
// judges. PIO0 runs `invert` and PIO1 `reverse`, exp220's two instances of
// one proved program; the CPU runs proof/Same.lean's kernel in User mode
// under tools/hazard3/harness.
//
//   1. PIO0 and PIO1 out of reset, each with its program, started.
//   2. Each of the message's 16 words goes both ways: PIO0 then PIO1, and
//      PIO1 then PIO0. What each block gives back alone is checked on the
//      way (INVERTED, REVERSED); what the two orders end with is not — the
//      first order's 16 words go to FIRST_OFF in the region, the second's
//      to SECOND_OFF. All four FIFOs empty afterwards.
//   3. The kernel's 292 bytes at the region's start, checked against
//      kernel.sha256, and the whole region hashed; then the kernel runs.
//   4. When it halts: it halted, the region is what it was (it writes
//      nothing, by `judges`), and minstret is the RTL's. Then its verdict is
//      the experiment's: HALT 0, the two orders gave the same 16 words; HALT
//      1, they did not.
//
// The shell carries every word and is not proved; it never compares the two
// orders itself. A step counter is written before each step, for the RTL
// build to name the step a trap came from.

#include <stdint.h>

#include "board.h"
#include "expect.h"
#include "pio.h"
#include "sha256.h"

#define csrr(name) ({ uint32_t v; __asm__ volatile ("csrr %0, " #name : "=r"(v)); v; })
#define REGION_SIZE 0x10000u
#define PATIENCE 1000000u      // mcycle ticks to wait for any one thing: ~0.1 s at ~11 MHz
#define BOTH_EMPTY (FSTAT_SM0_RXEMPTY | FSTAT_SM0_TXEMPTY)

extern void enter_payload(void) __attribute__((noreturn));

static volatile uint32_t step;
static uint32_t kernel_ok;
static uint8_t before[32];
static struct result res;

static int same(const uint8_t *a, const uint8_t *b, uint32_t n) {
    for (uint32_t i = 0; i < n; i++)
        if (a[i] != b[i]) return 0;
    return 1;
}

static int wait_for(uint32_t addr, uint32_t mask, uint32_t want) {
    uint32_t start = csrr(mcycle);
    while ((rd(addr) & mask) != want)
        if (csrr(mcycle) - start > PATIENCE) return 0;
    return 1;
}

static void report(uint32_t verdict) {
    res.verdict = verdict;
    board_report(&res);
}

static void start(uint32_t base, uint32_t reset_bit, const uint16_t *prog, uint32_t verdict) {
    wr(RESETS_RESET_CLR, reset_bit);
    if (!wait_for(RESETS_RESET_DONE, reset_bit, reset_bit)) report(verdict);
    for (uint32_t i = 0; i < PROGRAM_LEN; i++) wr(PIOB_INSTR_MEM(base, i), prog[i]);
    wr(PIOB_SM0_EXECCTRL(base), EXECCTRL_WRAP(0, PROGRAM_LEN - 1));
    wr(PIOB_CTRL(base), CTRL_SM0_RESTART | CTRL_SM0_CLKDIV_RESTART);
    wr(PIOB_SM0_INSTR(base), JMP_0);
    wr(PIOB_CTRL(base), CTRL_SM0_ENABLE);
}

static uint32_t through(uint32_t base, uint32_t w) {
    res.block = base == PIO1;
    if (!wait_for(PIOB_FSTAT(base), FSTAT_SM0_TXFULL, 0)) report(V_SILENT);
    wr(PIOB_TXF0(base), w);
    if (!wait_for(PIOB_FSTAT(base), FSTAT_SM0_RXEMPTY, 0)) report(V_SILENT);
    return rd(PIOB_RXF0(base));
}

void shell_main(void) {
    step = 1;
    __asm__ volatile ("csrwi mcountinhibit, 4");   // mcycle runs; the harness takes the counters over later
    board_init();

    step = 2;
    start(PIO0, RESET_PIO0, INVERT, V_RESET0);
    start(PIO1, RESET_PIO1, REVERSE, V_RESET1);

    step = 3;
    volatile uint32_t *w = (volatile uint32_t *)REGION;
    for (uint32_t i = 0; i < REGION_SIZE / 4; i++) w[i] = 0;
    uint8_t *r = (uint8_t *)REGION;
    for (uint32_t i = 0; i < KERNEL_LEN; i++) r[i] = KERNEL[i];
    volatile uint32_t *first = (volatile uint32_t *)(REGION + FIRST_OFF);
    volatile uint32_t *second = (volatile uint32_t *)(REGION + SECOND_OFF);

    step = 4;
    for (uint32_t i = 0; i < 16; i++) {
        res.word = i;
        uint32_t inv = through(PIO0, WORDS[i]);
        if (inv != INVERTED[i]) report(V_INVERT);
        first[i] = through(PIO1, inv);
        uint32_t rev = through(PIO1, WORDS[i]);
        if (rev != REVERSED[i]) report(V_REVERSE);
        second[i] = through(PIO0, rev);
    }
    if ((rd(PIOB_FSTAT(PIO0)) & BOTH_EMPTY) != BOTH_EMPTY) { res.block = 0; report(V_LEFTOVER); }
    if ((rd(PIOB_FSTAT(PIO1)) & BOTH_EMPTY) != BOTH_EMPTY) { res.block = 1; report(V_LEFTOVER); }
    wr(PIOB_CTRL(PIO0), 0);
    wr(PIOB_CTRL(PIO1), 0);

    step = 5;
    uint8_t d[32];
    sha256(r, KERNEL_LEN, d);
    kernel_ok = same(d, KERNEL_SHA, 32);
    sha256(r, REGION_SIZE, before);
    enter_payload();
}

// Every trap: the payload's ecall, a payload fault, or the shell's own.
void handle(uint32_t *x) {
    uint32_t cause = csrr(mcause), instret = csrr(minstret);
    if (((csrr(mstatus) >> 11) & 3) == 3) board_fault(step, cause);

    step = 6;
    res.instret = instret;
    res.a0 = x[10];
    res.cause = cause;
    int halted = cause == 8 && x[5] == 1;
    uint8_t d[32];
    sha256((const uint8_t *)REGION, REGION_SIZE, d);
    // 1 the kernel's bytes, 2 it halted, 3 with 0 or 1, 4 the region unchanged
    int ok[5] = {0, kernel_ok, halted, halted && x[10] <= 1, same(d, before, 32)};
    for (uint32_t k = 1; k <= 4; k++)
        if (!ok[k]) res.failed = res.failed * 10 + k;
    if (res.failed || instret != EXPECT_INSTRET) report(V_KERNEL);
    report(x[10] == 0 ? V_OK : V_DIFFER);
}
