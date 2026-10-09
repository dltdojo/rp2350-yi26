// SPDX-License-Identifier: Apache-2.0
//
// exp224 — the shell: exp223's three sources and exp223's kernel, as before,
// but no check made here. For each source the shell only gathers the facts
// the checks are made on, into a record; then proof/Judge.lean's kernel reads
// the three records and halts with the verdict, and the shell shows it.
//
// For each source (tools/hazard3/shell/sources.h): the 128 KiB region zeroed,
// exp223's kernel.bin at its start, the samples at 0x3000; the record gets
//   SHA-256 of the kernel's bytes as they sit in the region, and kernel.sha256
//   SHA-256 of the samples' 4096 bytes, by board_sha
//   the region's hash before the run
// then exp223's kernel runs in User mode, and when it traps the record gets
//   mcause, t0 and a0 from the trap, and minstret
//   the RTL's minstret for HALT 0 and for HALT 1
//   the 32 bytes at 0x2140
//   the region's hash after: with 0x2140 to 0x2440 cleared first if a0 is 0,
//   as exp223's shell did — the one decision on a fact left here
//   whether board_sha reported an error, any of its three times
// After the third: the region zeroed, judge.bin at its start (checked against
// judge.sha256 — the one comparison left here, since nothing can judge the
// judge's own bytes but something outside it), the records at 0x1000, and the
// judge runs. Its HALT code is the verdict:
//   code = verdict | source << 3 | failures << 6
//
// A step counter is written before each step, for the RTL build to name the
// step a trap came from.

#include <stdint.h>

#include "board.h"
#include "expect.h"
#include "sha256.h"

#define csrr(name) ({ uint32_t v; __asm__ volatile ("csrr %0, " #name : "=r"(v)); v; })
#define SAMPLES_OFF 0x3000u
#define DIGEST_OFF  0x2140u
#define SCRATCH_END 0x2440u
#define RECORDS_OFF 0x1000u
#define N           1024u
#define NSOURCES    3u

extern void enter_payload(void) __attribute__((noreturn));

// One record, as proof/Judge.lean reads it.
struct record {
    uint32_t cause, t0, a0, instret, pass, fail, shaok, pad;
    uint8_t kh[32], ksha[32], dig[32], want[32], after[32], before[32];
    uint8_t rest[0x100 - 0xe0];
};

static volatile uint32_t step;
static uint32_t source, judging;
static uint32_t samples[N];
static struct record records[NSOURCES];

static int same(const uint8_t *a, const uint8_t *b, uint32_t n) {
    for (uint32_t i = 0; i < n; i++)
        if (a[i] != b[i]) return 0;
    return 1;
}

static void copy(uint8_t *to, const uint8_t *from, uint32_t n) {
    for (uint32_t i = 0; i < n; i++) to[i] = from[i];
}

static void report(uint32_t verdict, struct result *res) {
    res->verdict = verdict;
    board_report(res);
}

#include "sources.h"

static void zero_region(void) {
    volatile uint32_t *w = (volatile uint32_t *)REGION;
    for (uint32_t i = 0; i < REGION_SIZE / 4; i++) w[i] = 0;
}

// The three records at 0x1000 and the judge entered.
__attribute__((noreturn)) static void judge(void) {
    step = 6;
    judging = 1;
    zero_region();
    uint8_t *r = (uint8_t *)REGION;
    copy(r, JUDGE, JUDGE_LEN);
    copy(r + RECORDS_OFF, (const uint8_t *)records, sizeof records);
    uint8_t d[32];
    sha256(r, JUDGE_LEN, d);
    if (!same(d, JUDGE_SHA, 32)) {
        struct result res = {0};
        report(V_JUDGE, &res);
    }
    enter_payload();
}

// Source `source` in the region and exp223's kernel entered; or, after the
// last, the judge.
__attribute__((noreturn)) static void next_source(void) {
    if (source == NSOURCES) judge();
    step = 2;
    gather();

    step = 3;
    zero_region();
    volatile uint32_t *w = (volatile uint32_t *)REGION;
    uint8_t *r = (uint8_t *)REGION;
    for (uint32_t i = 0; i < KERNEL_LEN; i++) r[i] = KERNEL[i];
    for (uint32_t i = 0; i < N; i++) w[SAMPLES_OFF / 4 + i] = samples[i];

    step = 4;
    struct record *rec = &records[source];
    sha256(r, KERNEL_LEN, rec->kh);
    copy(rec->ksha, KERNEL_SHA, 32);
    rec->pass = INSTRET_PASS;
    rec->fail = INSTRET_FAIL;
    rec->shaok = board_sha(r + SAMPLES_OFF, 4 * N, rec->want);
    rec->shaok &= board_sha(r, REGION_SIZE, rec->before);
    enter_payload();
}

void shell_main(void) {
    step = 1;
    __asm__ volatile ("csrwi mcountinhibit, 4");   // mcycle runs; the harness takes the counters over later
    board_init();
    source = 0;
    next_source();
}

// Every trap: a payload's ecall, a payload fault, or the shell's own.
void handle(uint32_t *x) {
    uint32_t cause = csrr(mcause), instret = csrr(minstret);
    if (((csrr(mstatus) >> 11) & 3) == 3) board_fault(step, cause);
    __asm__ volatile ("csrwi mcountinhibit, 4");   // the harness held mcycle too; the TRNG's wait needs it

    if (judging) {
        step = 7;
        struct result res = {0};
        res.a0 = x[10];
        res.instret = instret;
        res.cause = cause;
        if (cause != 8 || x[5] != 1) report(V_JUDGE, &res);
        res.source = (x[10] >> 3) & 7;
        res.failed = x[10] >> 6;
        report(x[10] & 7, &res);
    }

    step = 5;
    struct record *rec = &records[source];
    uint8_t *r = (uint8_t *)REGION;
    volatile uint8_t *v = (volatile uint8_t *)REGION;
    rec->cause = cause;
    rec->t0 = x[5];
    rec->a0 = x[10];
    rec->instret = instret;
    copy(rec->dig, r + DIGEST_OFF, 32);
    if (x[10] == 0)
        for (uint32_t i = DIGEST_OFF; i < SCRATCH_END; i++) v[i] = 0;
    rec->shaok &= board_sha(r, REGION_SIZE, rec->after);

    source++;
    next_source();
}
