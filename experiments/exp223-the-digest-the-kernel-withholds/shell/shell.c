// SPDX-License-Identifier: Apache-2.0
//
// exp223 — the shell: three sources of 1024 samples (tools/hazard3/shell/
// sources.h), each conditioned or withheld by proof/Condition.lean's kernel in
// User mode under tools/hazard3/harness, in a 128 KiB region.
//
// For each: the region zeroed, kernel.bin's 8484 bytes at its start (checked
// against kernel.sha256), the samples at 0x3000; SHA-256 of the samples' 4096
// bytes taken by board_sha — the chip's SHA-256 block, or sha256.c on the
// RTL — and the region hashed. Then the kernel runs. When it halts, the shell
// checks what `conditions` says: it halted, minstret is the RTL's count for
// the code it halted with, and
//   HALT 1: the region is exactly as it was — no digest, not a byte written;
//   HALT 0: the 32 bytes at 0x2140 are board_sha's digest of the samples, and
//           with the digest and SHA-256's scratch (0x2140 to 0x2440) cleared,
//           the region is exactly as it was.
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
#define SAMPLES_OFF 0x3000u
#define DIGEST_OFF  0x2140u
#define SCRATCH_END 0x2440u
#define N           1024u
#define NSOURCES    3u

extern void enter_payload(void) __attribute__((noreturn));

static volatile uint32_t step;
static uint32_t source, kernel_ok, sha_ok;
static uint8_t before[32], want[32];
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

#include "sources.h"

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
    sha_ok = board_sha(r + SAMPLES_OFF, 4 * N, want);
    sha_ok &= board_sha(r, REGION_SIZE, before);
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
    uint8_t *r = (uint8_t *)REGION;
    volatile uint8_t *v = (volatile uint8_t *)REGION;

    // 1 the kernel's bytes, 2 it halted, with 0 or 1, 3 minstret for that code,
    // 4 the digest is SHA-256's (HALT 0 only), 5 the rest of the region as it was
    int digest_ok = 1;
    if (halted && a0 == 0) {
        digest_ok = same(r + DIGEST_OFF, want, 32);
        for (uint32_t i = DIGEST_OFF; i < SCRATCH_END; i++) v[i] = 0;
    }
    uint8_t d[32];
    int region_ok = board_sha(r, REGION_SIZE, d) && same(d, before, 32);
    int ok[6] = {0, kernel_ok && sha_ok, halted && a0 <= 1,
                 instret == (a0 == 0 ? INSTRET_PASS : INSTRET_FAIL), digest_ok, region_ok};
    for (uint32_t k = 1; k <= 5; k++)
        if (!ok[k]) res.failed = res.failed * 10 + k;
    if (res.failed) report(V_KERNEL, &res);
    if (source == 0 && a0 != 0) report(V_WITHHELD, &res);
    if (source != 0 && a0 != 1) report(V_LET_PASS, &res);

    source++;
    next_source();
}
