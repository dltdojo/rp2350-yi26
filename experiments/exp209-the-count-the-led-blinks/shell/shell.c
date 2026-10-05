// SPDX-License-Identifier: Apache-2.0
//
// exp209 — the shell: put exp203's image in the region, check kernel.bin's
// SHA-256, run it in User mode under tools/hazard3/harness/harness.S — the
// same instructions around the payload as on the RTL — and check what it left.
//
// Checks, in order; the first that fails is the one reported:
//
//   1  kernel.bin's bytes in SRAM hash to kernel.sha256
//   2  PMP entry 0 reads back as the harness wrote it
//   3  the payload halted: ecall with t0 = 1
//   4  its result, a0, is 0
//   5  the 64 bytes at the destination are the 64 at the source
//   6  the whole 64 KiB region hashes to what the Lean model left there
//
// A step counter is written before each step and never after, so a trap in
// the shell itself names the step that did not come back.

#include <stdint.h>

#include "board.h"
#include "expect.h"
#include "sha256.h"

#define csrr(name) ({ uint32_t v; __asm__ volatile ("csrr %0, " #name : "=r"(v)); v; })
#define REGION_SIZE 0x10000u

extern void enter_payload(void) __attribute__((noreturn));

static volatile uint32_t step;
static uint32_t kernel_ok;

static int same(const uint8_t *a, const uint8_t *b, uint32_t n) {
    for (uint32_t i = 0; i < n; i++)
        if (a[i] != b[i]) return 0;
    return 1;
}

void shell_main(void) {
    step = 1;
    board_init();

    step = 2;
    volatile uint32_t *w = (volatile uint32_t *)REGION;
    for (uint32_t i = 0; i < REGION_SIZE / 4; i++) w[i] = 0;
    uint8_t *r = (uint8_t *)REGION;
    for (uint32_t b = 0; b < IMAGE_BLOCKS; b++)
        for (uint32_t j = 0; j < 64; j++) r[IMAGE_OFFSET[b] + j] = IMAGE_DATA[b][j];

    step = 3;
    uint8_t d[32];
    sha256(r, KERNEL_LEN, d);
    kernel_ok = same(d, KERNEL_SHA, 32);

    step = 4;
    enter_payload();
}

// Every trap: the payload's ecall, a payload fault, or the shell's own.
void handle(uint32_t *x) {
    uint32_t cause = csrr(mcause), instret = csrr(minstret), cycles = csrr(mcycle);
    if (((csrr(mstatus) >> 11) & 3) == 3) board_fault(step, cause);

    step = 5;
    struct result res = {0};
    res.instret = instret;
    res.cycles = cycles;
    res.a0 = x[10];
    res.cause = cause;
    int halted = cause == 8 && x[5] == 1;
    const uint8_t *r = (const uint8_t *)REGION;
    uint8_t d[32];
    sha256(r, REGION_SIZE, d);
    int pmp_ok = (csrr(pmpcfg0) & 0xff) == 0x1f
        && csrr(pmpaddr0) == ((REGION >> 2) | ((REGION_SIZE >> 3) - 1));

    if (!kernel_ok) res.failed = 1;
    else if (!pmp_ok) res.failed = 2;
    else if (!halted) res.failed = 3;
    else if (x[10] != 0) res.failed = 4;
    else if (!same(r + DST_OFF, r + SRC_OFF, 64)) res.failed = 5;
    else if (!same(d, REGION_SHA, 32)) res.failed = 6;
    res.number = halted ? instret : cause;
    board_report(&res);
}
