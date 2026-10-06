// SPDX-License-Identifier: Apache-2.0
//
// exp212 — the one decision the LED reports, from every run's result. Pure,
// so host/verdicttest.c can hold it against every way it could go wrong
// without a board or the RTL.
//
// Slow blinking for the one answer that means everything held; otherwise a
// count of flashes, the first of these that applies:
//
//   V_SLOW          every run passed every check; every seed of a kind took
//                   the same mcycle; the other message did not take the
//                   signer's; and each of those is the number the RTL counted
//   1 V_CHECK       a check failed, or a run is missing
//   2 V_NOT_RTL     every seed alike and the other message moved, but
//                   silicon's number is not the RTL's
//   3 V_FIRST       only the first key generation is out of line: every other
//                   key generation alike, every signature alike, the other
//                   message moved — the shell's own cold start, not the seed
//   4 V_KEYGEN      the key generations differ, beyond the first alone
//   5 V_SIGN        the signatures differ
//   6 V_BLIND       the other message took the signer's time: a measurement
//                   that cannot see a difference
//
// Revision 1 said only slow, double (2) or fast (1, 3, 4, 5 and 6 together),
// and a board said fast. Revision 2 said which, and a board said 3: the
// shell's first run alone. So revision 3 starts with a KEYGEN_WARM run —
// seed 0's key generation, held to every check and to nothing about its
// cycles — and every answer above is about the runs after it. 3 now means
// the first *timed* key generation, seed 0's second, is the odd one out:
// if the first run was the cold shell, it is not.
#pragma once
#include <stdint.h>

enum { V_SLOW = 0, V_CHECK, V_NOT_RTL, V_FIRST, V_KEYGEN, V_SIGN, V_BLIND };

// One run, as the shell found it: the failed checks as decimal digits, and
// the cycles the kernel ran for.
struct result { uint32_t failed, cycles; };

#define NKINDS 3
#define NONE 0xffffffffu

// runs[i].kind and runs[i].cycles (the RTL's) for each of n runs; ran is how
// many results the shell filled.
static inline uint32_t verdict(const struct run *runs, const struct result *res, uint32_t n, uint32_t ran) {
    if (ran != n) return V_CHECK;
    uint32_t first[NKINDS] = {NONE, NONE, NONE};
    uint32_t second_keygen = NONE;
    for (uint32_t i = 0; i < n; i++) {
        if (res[i].failed) return V_CHECK;
        uint32_t k = runs[i].kind;
        if (k == KEYGEN_WARM) continue;
        if (first[k] == NONE) first[k] = i;
        else if (k == KEYGEN && second_keygen == NONE) second_keygen = i;
    }
    for (uint32_t k = 0; k < NKINDS; k++)
        if (first[k] == NONE) return V_CHECK;
    if (second_keygen == NONE) return V_CHECK;

    // Each kind against its first run; the key generations also against the
    // second, so that the first alone being out of line can be told apart.
    uint32_t keygen_all = 1, keygen_rest = 1, sign_all = 1, rtl = 1;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t k = runs[i].kind, c = res[i].cycles;
        if (k == KEYGEN_WARM) continue;
        if (k == KEYGEN) {
            if (c != res[first[KEYGEN]].cycles) keygen_all = 0;
            if (i != first[KEYGEN] && c != res[second_keygen].cycles) keygen_rest = 0;
        } else if (k == SIGN && c != res[first[SIGN]].cycles) {
            sign_all = 0;
        }
        if (c != runs[i].cycles) rtl = 0;
    }
    uint32_t moved = res[first[SIGN_OTHER]].cycles != res[first[SIGN]].cycles;

    if (!keygen_all && keygen_rest && sign_all && moved) return V_FIRST;
    if (!keygen_all) return V_KEYGEN;
    if (!sign_all) return V_SIGN;
    if (!moved) return V_BLIND;
    return rtl ? V_SLOW : V_NOT_RTL;
}
