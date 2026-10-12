// SPDX-License-Identifier: Apache-2.0
//
// exp234 — the shell: exp232's search and trial, every generation of both
// written by one proved kernel, the world's (proof/World.lean), in a 64 KiB
// region in User mode under tools/hazard3/harness.
//
// The kernel is loaded once and its bytes checked against their hash. By
// `lives` each run, from any memory that begins with those bytes, halts with 0
// after 4043 instructions, having written 64 generations of the world —
// tumour, tissue, resistant — for the tumour, tissue and schedule at 0x200 and
// the 64 masks at 0x300, and changed nothing else, so the next run needs only
// new inputs. Every run is checked:
//   2 it halted (ecall, t0 = 1) with 0
//   3 minstret is the RTL's count, the same for every input
//
// The search is exp232's, with every mask zero — which by `still` (W0) makes
// the world exp232's proved model: CANDIDATES schedules from xorshift32, each
// cut to the trial's DAYS, accepted if for every enrolled width the patient
// meets the stated endpoint, the answer the accepted one with fewest doses.
//   4 the answer, the counts and the first loophole are world.py's
// Then the protocol is hashed and shown before the first patient is drawn.
//
// The trial, forever: each patient from one random word (the TRNG on the
// chip), into an arm by its low bit, a lump of 1 to WIDTH_MAX cells somewhere
// on the ring, and two runs of the same kernel. The model: every mask zero.
// The world: the masks exp232's world drew from the word — four xorshift32
// words ANDed for each generation, a one in about 1/16 of the bits. Nothing
// here computes a generation; the draw is the only unproved arithmetic left,
// and the theorems hold for every draw. Two of them are checked again on every
// patient, as what the chip must show if it runs what was proved:
//   10 no cell ever resistant: the world's 64 generations are the model's (W0,
//      `quiet`)
//   12 a cell resistant: the tumour is never gone from then on (M6,
//      `resistance_stays`)
//
// A step counter is written before each step, for the RTL build to name the
// step a trap came from.

#include <stdint.h>

#include "board.h"
#include "world.h"
#define STRIDE 3
#include "ring.h"
#include "sha256.h"

#define csrr(name) ({ uint32_t v; __asm__ volatile ("csrr %0, " #name : "=r"(v)); v; })
#define REGION_SIZE 0x10000u
#define INIT_OFF 0x200u
#define MASKS_OFF 0x300u
#define HIST_OFF 0x400u
#define ONES 0xffffffffu
#define BATCH 6

extern void enter_payload(void) __attribute__((noreturn));

static volatile uint32_t step;
static uint32_t phase;              // 0 the search, 1 a patient's model, 2 its world
static uint32_t hist[3 * GENS];     // the last run's generations: tumour, tissue, resistant
static uint32_t model[3 * GENS];
static uint32_t masks[GENS];
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

// The masks: every one zero, or the world's draw from `word` (exp232's).
static void draw(uint32_t word) {
    uint32_t r = word ? word : 1;
    for (uint32_t g = 0; g < GENS; g++) {
        uint32_t mut = ONES;
        for (uint32_t i = 0; i < MUT_BITS; i++) {
            r = xorshift(r);
            mut &= r;
        }
        masks[g] = mut;
    }
}

__attribute__((noreturn)) static void run(uint32_t t, uint32_t h, uint32_t s, int world) {
    volatile uint32_t *w = (volatile uint32_t *)REGION;
    w[INIT_OFF / 4] = t;
    w[INIT_OFF / 4 + 1] = h;
    w[INIT_OFF / 4 + 2] = s;
    for (uint32_t g = 0; g < GENS; g++) w[MASKS_OFF / 4 + g] = world ? masks[g] : 0;
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
        next_patient();
    }
    x = xorshift(x);
    cand = x & ((1u << DAYS) - 1);
    sr.tried++;
    width = 1;
    relapses = 0;
    run(lump(1, 0), ~lump(1, 0), cand, 0);
}

// The world's run is over: what it says, and the two theorems held to it.
static void judge(void) {
    uint32_t ever = 0, tissue = 32;
    for (uint32_t g = 0; g < GENS; g++) {
        if (ever && !hist[3 * g]) board_fail(12, g);
        ever |= hist[3 * g + 2];
        if (g < DAYS && pc(hist[3 * g + 1]) < tissue) tissue = pc(hist[3 * g + 1]);
    }
    if (!ever)
        for (uint32_t i = 0; i < 3 * GENS; i++)
            if (hist[i] != model[i]) board_fail(10, i);
    pt.world = outcome(hist);
    pt.resistant = ever != 0;
    pt.t24 = pc(hist[3 * (DAYS - 1)]);
    pt.tissue = tissue;
    pt.t64 = pc(hist[3 * (GENS - 1)]);
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
    phase = 1;
    uint32_t t = lump(pt.width, pt.at);
    run(t, ~t, pt.arm ? sr.answer : 0, 0);
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
    for (uint32_t i = 0; i < 3 * GENS; i++) hist[i] = w[HIST_OFF / 4 + i];

    if (phase == 0) {
        if (!endpoint(hist)) next_candidate();
        if (hist[3 * (GENS - 1)]) relapses = 1;
        if (width < WIDTH_MAX) {
            width++;
            run(lump(width, 0), ~lump(width, 0), cand, 0);
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

    if (phase == 1) {
        for (uint32_t i = 0; i < 3 * GENS; i++) model[i] = hist[i];
        pt.model = outcome(model);
        draw(pt.word);
        phase = 2;
        uint32_t t = lump(pt.width, pt.at);
        run(t, ~t, pt.arm ? sr.answer : 0, 1);
    }

    judge();
    tl.arm[pt.arm]++;
    tl.outcome[pt.arm][pt.world]++;
    if (pt.model == 0) tl.predicted[pt.arm]++;
    step = 9;
    board_patient(&sr, plan, &pt, &tl);
    next_patient();
}
