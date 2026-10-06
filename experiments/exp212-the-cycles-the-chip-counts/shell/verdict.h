// SPDX-License-Identifier: Apache-2.0
//
// exp212 — the one decision the LED reports, from every run's result. Pure,
// so host/verdicttest.c can hold it against every way it could go wrong
// without a board or the RTL.
//
//   SLOW     every run passed every check; every seed of a kind took the
//            same mcycle; the other message did not take the signer's; and
//            each of those is the number the RTL counted
//   DOUBLE   all of that, except that silicon's number is not the RTL's
//   FAST     anything else: a check failed, a run is missing, two seeds of
//            a kind took different times, or the other message took the
//            signer's time — a measurement that cannot see a difference
#pragma once
#include <stdint.h>

enum { FAST = 0, DOUBLE = 1, SLOW = 2 };

// One run, as the shell found it: the failed checks as decimal digits, and
// the cycles the kernel ran for.
struct result { uint32_t failed, cycles; };

#define NKINDS 3
#define NONE 0xffffffffu

// runs[i].kind and runs[i].cycles (the RTL's) for each of n runs; ran is how
// many results the shell filled.
static inline uint32_t verdict(const struct run *runs, const struct result *res, uint32_t n, uint32_t ran) {
    if (ran != n) return FAST;
    uint32_t first[NKINDS] = {NONE, NONE, NONE};
    uint32_t rtl = 1;
    for (uint32_t i = 0; i < n; i++) {
        if (res[i].failed) return FAST;
        uint32_t k = runs[i].kind;
        if (first[k] == NONE) first[k] = i;
        else if (res[i].cycles != res[first[k]].cycles) return FAST;
        if (res[i].cycles != runs[i].cycles) rtl = 0;
    }
    for (uint32_t k = 0; k < NKINDS; k++)
        if (first[k] == NONE) return FAST;
    if (res[first[SIGN_OTHER]].cycles == res[first[SIGN]].cycles) return FAST;
    return rtl ? SLOW : DOUBLE;
}
