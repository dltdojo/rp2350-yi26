// SPDX-License-Identifier: Apache-2.0
//
// exp211 — shell/counter.h on this machine, over a fake NOR flash that the
// power can be cut out of at any step. The fake is the datasheet's NOR: an
// erase sets bits to 1, a program only clears them, and a cut in the middle
// of either leaves an arbitrary subset of the bits it was changing changed.
//
// A run is boots until the counter says every leaf is used. Each boot is the
// shell's: ctr_begin, then sign the leaf it claimed, then confirm it. The
// steps a cut can land in are every erase, every program, and the signing
// itself (the window the board asks a person to pull the power in). For every
// one of them, and every pair, and each way a cut write can tear, it checks:
//
//   no leaf is signed twice                       (model: NoLeafTwice)
//   the run still ends with every leaf used       (a cut wastes, never wedges)
//   signed + wasted = 16, and wasted <= cuts      (each cut costs one leaf at most)
//
// and that a flash which silently takes no program signs nothing, one which
// takes only part of each signs no leaf twice, and a flash already holding a
// claim after a free slot — which this code never writes — signs nothing.
//
// and the same from flash that starts all ones, all zeros, or random.
//
//   countertest            exit 0 = all of it holds

#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "counter.h"

#define WORDS (3 * 4096 / 4)
static uint32_t flash[WORDS];
static uint32_t rng = 1;
static uint32_t next(void) { return rng = rng * 1664525u + 1013904223u; }

static uint32_t at(uint32_t off) { return (off - CTR_MARK) / 4; }

// Cut points: the step numbers at which the power goes, and how a write
// being cut tears: TEAR_NONE (none of it happened), TEAR_ALL (all of it, then
// the cut), TEAR_SOME (a random subset of its bits).
enum { TEAR_NONE, TEAR_ALL, TEAR_SOME };
static uint32_t step, cuts[2], ncuts, tear;
static jmp_buf power;

static void maybe_cut(void (*apply)(uint32_t off, uint32_t v, uint32_t mask), uint32_t off, uint32_t v) {
    uint32_t here = step++;
    for (uint32_t i = 0; i < ncuts; i++)
        if (cuts[i] == here) {
            if (apply) apply(off, v, tear == TEAR_NONE ? 0 : tear == TEAR_ALL ? ~0u : next());
            longjmp(power, 1);
        }
    if (apply) apply(off, v, ~0u);
}

uint32_t flash_word(uint32_t off) { return flash[at(off)]; }

static void erase(uint32_t off, uint32_t unused, uint32_t mask) {
    (void)unused;
    for (uint32_t i = 0; i < 1024; i++) flash[at(off) + i] |= mask == ~0u ? ~0u : (mask & next());
}
void flash_erase_sector(uint32_t off) { maybe_cut(erase, off, 0); }

// Two flashes that fail without a power cut, after formatting, and say
// nothing: STUCK takes no program at all; WEAK clears only some of the bits
// it was asked to, as a worn NOR cell can. The cases only the read-back in
// ctr_claim is there for, and the reason the read-back and the count must
// mean the same thing by "used".
enum { SOUND, STUCK, WEAK };
static uint32_t health = SOUND;

static void program(uint32_t off, uint32_t v, uint32_t mask) {
    if (off != CTR_MARK && health == STUCK) return;
    if (off != CTR_MARK && health == WEAK) mask &= next() | 1;
    flash[at(off)] &= v | ~mask;
}
void flash_program_word(uint32_t off, uint32_t v) { maybe_cut(program, off, v); }

// One run from the flash as it is: boots until the counter says exhausted.
// Returns 0 if every property held.
static int run(const char *what, int verbose) {
    uint32_t signed_[CTR_LEAVES] = {0}, boots = 0, signatures = 0;
    volatile uint32_t done = 0;
    struct ctr c;
    step = 0;
    while (!done) {
        if (++boots > 200) {
            if (verbose) printf("FAIL  %s: never exhausted\n", what);
            return 1;
        }
        if (setjmp(power)) continue;              // the power went: boot again
        uint32_t s = ctr_begin(&c);
        if (s == CTR_EXHAUSTED) {
            done = 1;
            break;
        }
        if (s != CTR_SIGN) continue;              // nothing signed; a cut may have caused it
        maybe_cut(0, 0, 0);                       // the window: claimed, not yet signed
        uint32_t leaf = c.used;
        signed_[leaf]++;
        signatures++;
        if (signed_[leaf] > 1) {
            if (verbose) printf("FAIL  %s: leaf %u signed twice\n", what, leaf);
            return 1;
        }
        ctr_confirm(leaf);
    }
    if (ctr_read(&c) != CTR_EXHAUSTED || c.used != CTR_LEAVES) {
        if (verbose) printf("FAIL  %s: ended with %u used\n", what, c.used);
        return 1;
    }
    // A leaf signed but cut before it was confirmed counts as wasted: what
    // the flash can say is "claimed, not confirmed".
    if (c.done + c.wasted != CTR_LEAVES || c.wasted > ncuts || signatures < c.done) {
        if (verbose) printf("FAIL  %s: %u done, %u wasted, %u cuts, %u signed\n", what, c.done, c.wasted, ncuts, signatures);
        return 1;
    }
    return 0;
}

static void fresh(uint32_t how) {
    for (uint32_t i = 0; i < WORDS; i++) flash[i] = how == 0 ? ~0u : how == 1 ? 0 : next();
    flash[0] = how == 2 ? 0x12345678u : flash[0];  // never the marker by chance
}

int main(void) {
    int failures = 0;
    char what[96];

    // How many steps a run with no cut takes.
    fresh(0);
    ncuts = 0;
    failures += run("no cut at all", 1);
    uint32_t steps = step;
    printf("%s  no cut: every leaf signed once, %u steps\n", failures ? "FAIL" : "PASS", steps);

    static const char *start[] = {"all ones", "all zeros", "random"};
    static const char *how[] = {"none of the write", "all of the write", "part of the write"};
    for (uint32_t f = 0; f < 3; f++) {
        int bad = 0;
        uint32_t tried = 0;
        for (tear = 0; tear < 3; tear++)
            for (uint32_t j = 0; j < steps + 8; j++) {
                fresh(f);
                cuts[0] = j, ncuts = 1;
                snprintf(what, sizeof what, "from %s, one cut at step %u, %s", start[f], j, how[tear]);
                bad += run(what, !bad);
                tried++;
            }
        printf("%s  from flash %s: a cut at each of %u steps, three ways a write tears — %u runs, no leaf twice, every run exhausts\n",
               bad ? "FAIL" : "PASS", start[f], steps + 8, tried);
        failures += bad;
    }

    int bad = 0;
    uint32_t tried = 0;
    for (tear = 0; tear < 3; tear++)
        for (uint32_t j = 0; j < steps; j++)
            for (uint32_t k = 0; k < steps; k++) {
                fresh(0);
                cuts[0] = j, cuts[1] = k, ncuts = 2;
                snprintf(what, sizeof what, "two cuts, at steps %u and %u, %s", j, k, how[tear]);
                bad += run(what, !bad);
                tried++;
            }
    printf("%s  two cuts at every pair of steps, three ways a write tears — %u runs, no leaf twice, every run exhausts\n",
           bad ? "FAIL" : "PASS", tried);
    failures += bad;

    // A flash that takes no program: every boot must refuse to sign.
    fresh(0);
    ncuts = 0, health = STUCK;
    uint32_t signatures = 0;
    struct ctr c;
    for (uint32_t b = 0; b < 4; b++) {
        step = 0;
        if (ctr_begin(&c) == CTR_SIGN) signatures++;
    }
    health = SOUND;
    printf("%s  a flash that silently takes no program: four boots, %u signatures — a claim the flash does not show is never signed under\n",
           signatures ? "FAIL" : "PASS", signatures);
    failures += signatures != 0;

    // A flash that takes part of each program, silently: whatever it shows,
    // no leaf twice.
    bad = 0;
    for (uint32_t r = 0; r < 200; r++) {
        fresh(0);
        ncuts = 0, health = WEAK;
        snprintf(what, sizeof what, "a weak flash, run %u", r);
        bad += run(what, !bad);
    }
    health = SOUND;
    printf("%s  a flash that silently takes only part of each program: 200 runs, no leaf twice\n", bad ? "FAIL" : "PASS");
    failures += bad;

    // Formatted, leaves 0 and 2 claimed and confirmed, leaf 1 free: not
    // something this code writes. Signing anything here could sign leaf 2
    // again.
    fresh(0);
    ncuts = 0;
    flash[at(CTR_MARK)] = CTR_MAGIC;
    flash[at(ctr_claim_at(0))] = flash[at(ctr_done_at(0))] = 0;
    flash[at(ctr_claim_at(2))] = flash[at(ctr_done_at(2))] = 0;
    signatures = 0;
    for (uint32_t b = 0; b < 4; b++) {
        step = 0;
        if (ctr_begin(&c) == CTR_SIGN) signatures++;
    }
    printf("%s  a flash holding a claim after a free slot: four boots, %u signatures — what this code never writes, it never signs under\n",
           signatures ? "FAIL" : "PASS", signatures);
    failures += signatures != 0;

    return failures != 0;
}
