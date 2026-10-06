// SPDX-License-Identifier: Apache-2.0
//
// exp212 — the one decision the LED reports, from every run's result. Pure,
// so host/verdicttest.c can hold it against every way it could go wrong
// without a board or the RTL.
//
// The history, each line a board's answer:
//
//   revision 1   slow, double or fast — fast: something, it could not say what
//   revision 2   a count — 3: only the shell's first run was out of line
//   revision 3   a warm-up run first, untimed — 2: every seed alike, every
//                check held, and silicon's cycles are not the RTL's
//
// Revision 4 keeps the warm-up and the checks and asks the next question:
// how silicon's numbers differ from the RTL's. There are three kinds of run
// (the key generator, the signer, the signer on the other message), and for
// each the difference d = silicon − RTL. Two explanations predict a line:
//
//   per HASH call     d = a + c·S         S the kind's HASH calls: a cost in
//                                         the trap in and out, which the chip
//                                         fetches from flash and the RTL
//                                         from RAM
//   per instruction   d = a + b·minstret  a cost in every instruction: memory
//                                         slower than the RTL's
//
// Three points lie on a line or do not, exactly, in integers. The three
// kinds' (S, minstret) are not themselves on a line, so a d that is not
// constant fits at most one of the two; a constant d fits both, and is
// told apart first.
//
//   V_SLOW          every check held, every seed alike, and d = 0: the RTL's
//   1 V_CHECK       a check failed, or a run is missing
//   2 V_PER_HASH    d = a + c·S, and not constant
//   3 V_PER_INSN    d = a + b·minstret, and not constant
//   4 V_OFFSET      d the same for all three kinds, and not 0
//   5 V_NEITHER     d on neither line
//   6 V_SEEDS       two seeds of a kind took different times, or the other
//                   message took the signer's: revision 3 said neither
#pragma once
#include <stdint.h>

enum { V_SLOW = 0, V_CHECK, V_PER_HASH, V_PER_INSN, V_OFFSET, V_NEITHER, V_SEEDS };

// One run, as the shell found it: the failed checks as decimal digits, and
// the cycles the kernel ran for.
struct result { uint32_t failed, cycles; };

#define NKINDS 3
#define NONE 0xffffffffu

// Whether (x[k], d[k]) for the three kinds lie on one line.
static inline int on_a_line(const int64_t *x, const int64_t *d) {
    return (d[1] - d[0]) * (x[2] - x[1]) == (d[2] - d[1]) * (x[1] - x[0]);
}

// runs[i].kind, .cycles (the RTL's), .instret and .hashes for each of n runs;
// ran is how many results the shell filled.
static inline uint32_t verdict(const struct run *runs, const struct result *res, uint32_t n, uint32_t ran) {
    if (ran != n) return V_CHECK;
    uint32_t first[NKINDS] = {NONE, NONE, NONE};
    for (uint32_t i = 0; i < n; i++) {
        if (res[i].failed) return V_CHECK;
        uint32_t k = runs[i].kind;
        if (k == KEYGEN_WARM) continue;
        if (first[k] == NONE) first[k] = i;
        else if (res[i].cycles != res[first[k]].cycles) return V_SEEDS;
    }
    for (uint32_t k = 0; k < NKINDS; k++)
        if (first[k] == NONE) return V_CHECK;
    if (res[first[SIGN_OTHER]].cycles == res[first[SIGN]].cycles) return V_SEEDS;

    int64_t d[NKINDS], s[NKINDS], m[NKINDS];
    for (uint32_t k = 0; k < NKINDS; k++) {
        const struct run *r = &runs[first[k]];
        d[k] = (int64_t)res[first[k]].cycles - (int64_t)r->cycles;
        s[k] = r->hashes;
        m[k] = r->instret;
    }
    if (d[0] == d[1] && d[1] == d[2]) return d[0] == 0 ? V_SLOW : V_OFFSET;
    if (on_a_line(s, d)) return V_PER_HASH;
    if (on_a_line(m, d)) return V_PER_INSN;
    return V_NEITHER;
}
