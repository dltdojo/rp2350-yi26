// SPDX-License-Identifier: Apache-2.0
//
// exp232 — the shell: a search, then a trial, both made of runs of one proved
// kernel in a 64 KiB region, in User mode under tools/hazard3/harness.
//
// The kernel is loaded once and its bytes checked against their hash. By
// `models` (proof/Cure.lean) each run, from any memory that begins with those
// bytes, halts with 0 after 3081 instructions, having written 64 generations
// of the model for the tumour, tissue and schedule at 0x100, and changed
// nothing else — so the next run needs only new inputs. Every run is checked:
//   2 it halted (ecall, t0 = 1) with 0
//   3 minstret is the RTL's count, the same for every input
//
// The search — the stand-in for the AI: CANDIDATES schedules from xorshift32,
// each cut to the trial's DAYS. A schedule is accepted if, for every enrolled
// width from 1 to WIDTH_MAX, the kernel's patient meets the stated endpoint:
// no more than DETECT tumour cells after DAYS, and never less than TISSUE_MIN
// tissue before. The answer is the accepted one with fewest doses. Whether
// the tumour is still there at generation 64 is counted, and the goal never
// looks at it. Then
//   4 the answer, the counts and the first loophole are cure.py's
// and the protocol — the answer and every constant of the trial — is hashed
// and shown before the first patient is drawn.
//
// The trial, forever: each patient from one random word (the TRNG on the
// chip), into an arm by its low bit, a lump of 1 to WIDTH_MAX cells somewhere
// on the ring. The kernel gives the model's outcome. Then the world: the same
// rule, written again here and not proved, with one thing the model leaves
// out — a cell the tumour divides into is resistant with probability
// 2^-MUT_BITS, and a dose never kills a resistant cell or its daughters.
//   10 a patient in whom no cell ever became resistant lived exactly the
//      proved model's 64 generations
//
// A step counter is written before each step, for the RTL build to name the
// step a trap came from.

#include <stdint.h>

#include "board.h"
#include "cure.h"
#define STRIDE 2
#include "ring.h"
#include "sha256.h"

#define csrr(name) ({ uint32_t v; __asm__ volatile ("csrr %0, " #name : "=r"(v)); v; })
#define REGION_SIZE 0x10000u
#define INIT_OFF 0x100u
#define HIST_OFF 0x200u
#define ONES 0xffffffffu
#define BATCH 6

extern void enter_payload(void) __attribute__((noreturn));

static volatile uint32_t step;
static uint32_t phase;              // 0 the search, 1 the trial
static uint32_t hist[2 * GENS];     // the last run's generations: tumour, tissue
static uint32_t world[2 * GENS];
static uint8_t plan[32];

static struct search sr;
static uint32_t x, cand, width, relapses, have_loophole;

static struct patient pt;
static struct tally tl;
static uint32_t words[BATCH], left;   // no initialised data in a shell: 0 left means draw

static int same(const uint8_t *a, const uint8_t *b, uint32_t n) {
    for (uint32_t i = 0; i < n; i++)
        if (a[i] != b[i]) return 0;
    return 1;
}

// The region zeroed, the kernel at its start, its bytes its hash's: once.
static void load(void) {
    volatile uint32_t *w = (volatile uint32_t *)REGION;
    for (uint32_t i = 0; i < REGION_SIZE / 4; i++) w[i] = 0;
    uint8_t *b = (uint8_t *)REGION;
    for (uint32_t i = 0; i < KERNEL_LEN; i++) b[i] = KERNEL[i];
    uint8_t d[32];
    sha256(b, KERNEL_LEN, d);
    if (!same(d, KERNEL_SHA, 32)) board_fail(1, d[0]);
}

__attribute__((noreturn)) static void run(uint32_t t, uint32_t h, uint32_t s) {
    volatile uint32_t *w = (volatile uint32_t *)REGION;
    w[INIT_OFF / 4] = t;
    w[INIT_OFF / 4 + 1] = h;
    w[INIT_OFF / 4 + 2] = s;
    step = phase ? 7 : 3;
    enter_payload();
}

__attribute__((noreturn)) static void next_patient(void);

__attribute__((noreturn)) static void next_candidate(void) {
    board_tick();
    if (sr.tried == CANDIDATES) {
        step = 5;
        if (sr.answer != ANSWER || sr.accepted != ACCEPTED || sr.relapsing != RELAPSING || sr.loophole != LOOPHOLE)
            board_fail(4, sr.answer);
        const uint32_t protocol[8] = {sr.answer, DAYS, DETECT, TISSUE_MIN, WIDTH_MAX, MUT_BITS, CANDIDATES, SEARCH_SEED};
        uint8_t bytes[32];
        for (uint32_t i = 0; i < 32; i++) bytes[i] = (uint8_t)(protocol[i / 4] >> (8 * (i % 4)));
        sha256(bytes, 32, plan);
        board_searched(&sr, plan);
        phase = 1;
        next_patient();
    }
    x = xorshift(x);
    cand = x & ((1u << DAYS) - 1);
    sr.tried++;
    width = 1;
    relapses = 0;
    run(lump(1, 0), ~lump(1, 0), cand);
}

// The world: the model's rule with resistance, for the patient in pt.
static void live(void) {
    uint32_t t = lump(pt.width, pt.at), h = ~t, s = pt.arm ? sr.answer : 0;
    uint32_t res = 0, ever = 0, r = pt.word ? pt.word : 1, tissue = 32;
    for (uint32_t g = 0; g < GENS; g++) {
        uint32_t mut = ONES;
        for (uint32_t i = 0; i < MUT_BITS; i++) {
            r = xorshift(r);
            mut &= r;
        }
        uint32_t kill = (s & 1) ? (((spread(~t) & t) | (spread(~h) & h)) & ~res) : 0;
        uint32_t t1 = t & ~kill, h1 = h & ~kill;
        uint32_t t2 = t1 | up1(t1);
        uint32_t h2 = (h1 | (spread(h1) & ~(t1 | h1))) & ~t2;
        res = (res | up1(res) | (t2 & ~t1 & mut)) & t2;
        ever |= res;
        t = t2;
        h = h2;
        s >>= 1;
        world[2 * g] = t;
        world[2 * g + 1] = h;
        if (g < DAYS && pc(h) < tissue) tissue = pc(h);
    }
    pt.world = outcome(world);
    pt.resistant = ever != 0;
    pt.t24 = pc(world[2 * (DAYS - 1)]);
    pt.tissue = tissue;
    pt.t64 = pc(world[2 * (GENS - 1)]);
    if (!ever)
        for (uint32_t i = 0; i < 2 * GENS; i++)
            if (world[i] != hist[i]) board_fail(10, i);
}

__attribute__((noreturn)) static void next_patient(void) {
    step = 6;
    if (!left) {
        if (!board_trng(words, BATCH)) board_fail(11, 0);
        left = BATCH;
    }
    uint32_t r = words[BATCH - left--];
    pt.n++;
    pt.word = r;
    pt.arm = r & 1;
    pt.width = 1 + ((r >> 1) % WIDTH_MAX);
    pt.at = (r >> 4) & 31;
    uint32_t t = lump(pt.width, pt.at);
    run(t, ~t, pt.arm ? sr.answer : 0);
}

void shell_main(void) {
    step = 1;
    __asm__ volatile ("csrwi mcountinhibit, 4");   // mcycle runs; the harness takes the counters over later
    board_init();
    step = 2;
    load();
    x = SEARCH_SEED;
    next_candidate();
}

// Every trap: a payload's ecall, a payload fault, or the shell's own.
void handle(uint32_t *xr) {
    uint32_t cause = csrr(mcause), instret = csrr(minstret);
    if (((csrr(mstatus) >> 11) & 3) == 3) board_fault(step, cause);
    __asm__ volatile ("csrwi mcountinhibit, 4");   // the harness held mcycle too; the LED's beat needs it
    step = phase ? 8 : 4;
    if (cause != 8 || xr[5] != 1 || xr[10] != 0) board_fail(2, cause == 8 ? xr[10] : cause);
    if (instret != INSTRET) board_fail(3, instret);
    sr.instret = instret;
    const volatile uint32_t *w = (const volatile uint32_t *)REGION;
    for (uint32_t i = 0; i < 2 * GENS; i++) hist[i] = w[HIST_OFF / 4 + i];

    if (phase == 0) {
        if (!endpoint(hist)) next_candidate();
        if (hist[2 * (GENS - 1)]) relapses = 1;
        if (width < WIDTH_MAX) {
            width++;
            run(lump(width, 0), ~lump(width, 0), cand);
        }
        sr.accepted++;
        if (relapses) {
            sr.relapsing++;
            if (!have_loophole) sr.loophole = cand;
            have_loophole = 1;
        }
        if (sr.accepted == 1 || pc(cand) < pc(sr.answer)) sr.answer = cand;
        next_candidate();
    }

    pt.model = outcome(hist);
    live();
    tl.arm[pt.arm]++;
    tl.outcome[pt.arm][pt.world]++;
    if (pt.model == 0) tl.predicted[pt.arm]++;
    step = 9;
    board_patient(&sr, plan, &pt, &tl);
    next_patient();
}
