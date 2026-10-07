// SPDX-License-Identifier: Apache-2.0
//
// exp220 — the shell: one CPU and two PIO blocks, each running bytes a Lean
// theorem is about. The CPU runs exp203's copy kernel in User mode, as exp219
// does; PIO0 runs `invert` and PIO1 `reverse`, proof/Through.lean's two
// instances of one proved program.
//
//   1. PIO0 and PIO1 out of reset, each with its program, started. TX is
//      empty, so each waits at `pull block`: `waits`.
//   2. exp203's image in the region, the message as its source; the kernel's
//      bytes checked against kernel.sha256.
//   3. Both blocks checked to be waiting, both FIFOs empty; the kernel runs.
//   4. When it halts, exp209's checks, as exp219's.
//   5. Each of the 16 copied words goes both ways: through PIO0 and then
//      PIO1, and through PIO1 and then PIO0. What each block gives back is
//      checked on the way (INVERTED, REVERSED), and both orders must end at
//      ANSWERS — the same word, by `either_order`.
//   6. All four FIFOs empty at the end.
//
// The shell carries the words between the three, and is not proved. A step
// counter is written before each step, for the RTL build to name the step a
// trap came from.

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
static uint32_t kernel_ok, waiting;
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

// One word into a block and back.
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
    for (uint32_t b = 0; b < IMAGE_BLOCKS; b++)
        for (uint32_t j = 0; j < 64; j++) r[IMAGE_OFFSET[b] + j] = IMAGE_DATA[b][j];
    uint8_t d[32];
    sha256(r, KERNEL_LEN, d);
    kernel_ok = same(d, KERNEL_SHA, 32);

    step = 4;
    waiting = (rd(PIOB_FSTAT(PIO0)) & BOTH_EMPTY) == BOTH_EMPTY && (rd(PIOB_FSTAT(PIO1)) & BOTH_EMPTY) == BOTH_EMPTY;
    enter_payload();
}

// Every trap: the payload's ecall, a payload fault, or the shell's own.
void handle(uint32_t *x) {
    uint32_t cause = csrr(mcause), instret = csrr(minstret);
    if (((csrr(mstatus) >> 11) & 3) == 3) board_fault(step, cause);
    __asm__ volatile ("csrwi mcountinhibit, 4");   // the harness held mcycle too; the waits below need it

    step = 5;
    res.instret = instret;
    res.a0 = x[10];
    res.cause = cause;
    int halted = cause == 8 && x[5] == 1;
    const uint8_t *r = (const uint8_t *)REGION;
    uint8_t d[32];
    sha256(r, REGION_SIZE, d);
    int ok[6] = {0, kernel_ok, 1, halted, halted && x[10] == 0, same(r + DST_OFF, r + SRC_OFF, 64)};
    for (uint32_t k = 1; k <= 5; k++)
        if (!ok[k]) res.failed = res.failed * 10 + k;
    if (!same(d, REGION_SHA, 32)) res.failed = res.failed * 10 + 6;
    if (res.failed || instret != EXPECT_INSTRET) report(V_KERNEL);
    if (!waiting) report(V_BUSY);

    step = 6;
    const volatile uint32_t *dst = (const volatile uint32_t *)(REGION + DST_OFF);
    for (uint32_t i = 0; i < 16; i++) {
        res.word = i;
        uint32_t inv = through(PIO0, dst[i]);
        if (inv != INVERTED[i]) report(V_INVERT);
        uint32_t a = through(PIO1, inv);
        uint32_t rev = through(PIO1, dst[i]);
        if (rev != REVERSED[i]) report(V_REVERSE);
        uint32_t b = through(PIO0, rev);
        if (a != ANSWERS[i] || b != ANSWERS[i]) report(V_ORDER);
    }

    step = 7;
    if ((rd(PIOB_FSTAT(PIO0)) & BOTH_EMPTY) != BOTH_EMPTY) { res.block = 0; report(V_LEFTOVER); }
    if ((rd(PIOB_FSTAT(PIO1)) & BOTH_EMPTY) != BOTH_EMPTY) { res.block = 1; report(V_LEFTOVER); }
    wr(PIOB_CTRL(PIO0), 0);
    wr(PIOB_CTRL(PIO1), 0);
    report(V_OK);
}
