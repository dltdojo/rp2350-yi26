// SPDX-License-Identifier: Apache-2.0
//
// exp222 — the shell: three sources of 1024 samples, each judged by
// proof/Health.lean's kernel in User mode under tools/hazard3/harness.
//
//   0  the TRNG: 32 words from it, each split into 32 samples, bit by bit
//   1  a source stuck at 1, which the repetition count must catch
//   2  nine ones then a zero, over and over: exp114's broken source, which
//      the adaptive proportion test must catch
//
// For each: the region zeroed, the kernel's 192 bytes at its start (checked
// against kernel.sha256), the samples at 0x1000, and the region hashed; then
// the kernel runs. When it halts, the shell checks what `withholds` says:
// it halted, minstret is the RTL's count for the code it halted with, and
//   HALT 1: the region is exactly as it was — not a byte written;
//   HALT 0: the output at 0x2000 is the samples, word for word, and with it
//           cleared the region is exactly as it was.
// Then the code itself: the TRNG's samples should pass (0) and both broken
// sources should be withheld (1).
//
// The shell gathers the samples and is not proved; what the kernel does with
// them is. A step counter is written before each step, for the RTL build to
// name the step a trap came from.

#include <stdint.h>

#include "board.h"
#include "expect.h"
#include "sha256.h"

#define csrr(name) ({ uint32_t v; __asm__ volatile ("csrr %0, " #name : "=r"(v)); v; })
#define REGION_SIZE 0x10000u
#define SAMPLES_OFF 0x1000u
#define OUT_OFF     0x2000u
#define N           1024u
#define NSOURCES    3u

extern void enter_payload(void) __attribute__((noreturn));

static volatile uint32_t step;
static uint32_t source, kernel_ok;
static uint8_t before[32];
static uint32_t samples[N];

static int same(const uint8_t *a, const uint8_t *b, uint32_t n) {
    for (uint32_t i = 0; i < n; i++)
        if (a[i] != b[i]) return 0;
    return 1;
}

static void report(uint32_t verdict, struct result *res) {
    res->verdict = verdict;
    res->source = source;
    board_report(res);
}

// Source `source`'s samples, into `samples`.
static void gather(void) {
    if (source == 0) {
        uint32_t w[N / 32];
        if (!board_trng(w, N / 32)) {
            struct result res = {0};
            report(V_SILENT, &res);
        }
        for (uint32_t i = 0; i < N; i++) samples[i] = (w[i / 32] >> (i % 32)) & 1u;
    } else if (source == 1) {
        for (uint32_t i = 0; i < N; i++) samples[i] = 1;
    } else {
        for (uint32_t i = 0; i < N; i++) samples[i] = i % 10 < 9;
    }
}

// Source `source` in the region and the kernel entered; or, after the last, ok.
__attribute__((noreturn)) static void next_source(void) {
    if (source == NSOURCES) {
        struct result res = {0};
        report(V_OK, &res);
    }
    step = 2;
    gather();

    step = 3;
    volatile uint32_t *w = (volatile uint32_t *)REGION;
    for (uint32_t i = 0; i < REGION_SIZE / 4; i++) w[i] = 0;
    uint8_t *r = (uint8_t *)REGION;
    for (uint32_t i = 0; i < KERNEL_LEN; i++) r[i] = KERNEL[i];
    for (uint32_t i = 0; i < N; i++) w[SAMPLES_OFF / 4 + i] = samples[i];

    step = 4;
    uint8_t d[32];
    sha256(r, KERNEL_LEN, d);
    kernel_ok = same(d, KERNEL_SHA, 32);
    sha256(r, REGION_SIZE, before);
    enter_payload();
}

void shell_main(void) {
    step = 1;
    __asm__ volatile ("csrwi mcountinhibit, 4");   // mcycle runs; the harness takes the counters over later
    board_init();
    source = 0;
    next_source();
}

// Every trap: the payload's ecall, a payload fault, or the shell's own.
void handle(uint32_t *x) {
    uint32_t cause = csrr(mcause), instret = csrr(minstret);
    if (((csrr(mstatus) >> 11) & 3) == 3) board_fault(step, cause);
    __asm__ volatile ("csrwi mcountinhibit, 4");   // the harness held mcycle too; the TRNG's wait needs it

    step = 5;
    struct result res = {0};
    res.a0 = x[10];
    res.instret = instret;
    res.cause = cause;
    int halted = cause == 8 && x[5] == 1;
    uint32_t a0 = x[10];
    volatile uint32_t *w = (volatile uint32_t *)REGION;

    // 1 the kernel's bytes, 2 it halted, with 0 or 1, 3 minstret for that code,
    // 4 the output is the samples (HALT 0 only), 5 the rest of the region as it was
    int out_ok = 1;
    if (halted && a0 == 0)
        for (uint32_t i = 0; i < N; i++) {
            if (w[OUT_OFF / 4 + i] != samples[i]) out_ok = 0;
            w[OUT_OFF / 4 + i] = 0;
        }
    uint8_t d[32];
    sha256((const uint8_t *)REGION, REGION_SIZE, d);
    int ok[6] = {0, kernel_ok, halted && a0 <= 1, instret == (a0 == 0 ? INSTRET_PASS : INSTRET_FAIL),
                 out_ok, same(d, before, 32)};
    for (uint32_t k = 1; k <= 5; k++)
        if (!ok[k]) res.failed = res.failed * 10 + k;
    if (res.failed) report(V_KERNEL, &res);
    if (source == 0 && a0 != 0) report(V_WITHHELD, &res);
    if (source != 0 && a0 != 1) report(V_LET_PASS, &res);

    source++;
    next_source();
}
