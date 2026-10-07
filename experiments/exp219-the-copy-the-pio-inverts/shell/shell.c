// SPDX-License-Identifier: Apache-2.0
//
// exp219 — the shell: two pieces of proved bytes on one chip. PIO0 runs
// exp214's `invert`, the three words exp217's theorems are about, and the
// CPU runs exp203's copy kernel, the sixty bytes exp203's theorems are about,
// in User mode under tools/hazard3/harness — as exp209 ran it.
//
//   1. PIO0 out of reset, `invert` loaded and started. TX is empty, so it
//      waits at `pull block`: exp217's `waits`.
//   2. exp203's image in the region, with the message as its source; the
//      kernel's bytes checked against kernel.sha256.
//   3. PIO0 checked to be waiting still, both FIFOs empty; then the kernel
//      runs, with PIO0 running beside it.
//   4. When it halts, exp209's checks: it halted, with 0, the destination is
//      the source, the whole region is what the Lean model left there, and
//      minstret is the RTL's.
//   5. The 16 words the kernel wrote at the destination go through PIO0 one
//      at a time; each must come back as ANSWERS says, the copied word
//      complemented. Both FIFOs empty at the end.
//
// The shell carries the words from one to the other, and is not proved;
// what each side does to them is. A step counter is written before each
// step, for the RTL build to name the step a trap came from.

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
static uint32_t kernel_ok, pio_waiting;

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

static void report(uint32_t verdict, struct result *res) {
    res->verdict = verdict;
    board_report(res);
}

void shell_main(void) {
    step = 1;
    struct result res = {0};
    __asm__ volatile ("csrwi mcountinhibit, 4");   // mcycle runs; the harness takes the counters over later
    board_init();

    step = 2;
    wr(RESETS_RESET_CLR, RESET_PIO0);
    if (!wait_for(RESETS_RESET_DONE, RESET_PIO0, RESET_PIO0)) report(V_RESET, &res);
    for (uint32_t i = 0; i < PROGRAM_LEN; i++) wr(PIO_INSTR_MEM(i), PROGRAM[i]);
    wr(PIO_SM0_EXECCTRL, EXECCTRL_WRAP(0, PROGRAM_LEN - 1));
    wr(PIO_CTRL, CTRL_SM0_RESTART | CTRL_SM0_CLKDIV_RESTART);
    wr(PIO_SM0_INSTR, JMP_0);
    wr(PIO_CTRL, CTRL_SM0_ENABLE);

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
    pio_waiting = (rd(PIO_FSTAT) & BOTH_EMPTY) == BOTH_EMPTY;
    enter_payload();
}

// Every trap: the payload's ecall, a payload fault, or the shell's own.
void handle(uint32_t *x) {
    uint32_t cause = csrr(mcause), instret = csrr(minstret);
    if (((csrr(mstatus) >> 11) & 3) == 3) board_fault(step, cause);
    __asm__ volatile ("csrwi mcountinhibit, 4");   // the harness held mcycle too; the waits below need it

    step = 5;
    struct result res = {0};
    res.instret = instret;
    res.a0 = x[10];
    res.cause = cause;
    int halted = cause == 8 && x[5] == 1;
    const uint8_t *r = (const uint8_t *)REGION;
    uint8_t d[32];
    sha256(r, REGION_SIZE, d);
    int ok[6] = {0, kernel_ok, 1, halted, halted && x[10] == 0, same(r + DST_OFF, r + SRC_OFF, 64)};
    int region = same(d, REGION_SHA, 32);
    for (uint32_t k = 1; k <= 5; k++)
        if (!ok[k]) res.failed = res.failed * 10 + k;
    if (!region) res.failed = res.failed * 10 + 6;
    if (res.failed || instret != EXPECT_INSTRET) report(V_KERNEL, &res);
    if (!pio_waiting) report(V_BUSY, &res);

    step = 6;
    const volatile uint32_t *dst = (const volatile uint32_t *)(REGION + DST_OFF);
    for (uint32_t i = 0; i < 16; i++) {
        res.word = i;
        if (!wait_for(PIO_FSTAT, FSTAT_SM0_TXFULL, 0)) report(V_SILENT, &res);
        wr(PIO_TXF0, dst[i]);
        if (!wait_for(PIO_FSTAT, FSTAT_SM0_RXEMPTY, 0)) report(V_SILENT, &res);
        if (rd(PIO_RXF0) != ANSWERS[i]) report(V_WRONG, &res);
    }

    step = 7;
    if ((rd(PIO_FSTAT) & BOTH_EMPTY) != BOTH_EMPTY) report(V_LEFTOVER, &res);
    wr(PIO_CTRL, 0);
    report(V_OK, &res);
}
