// SPDX-License-Identifier: Apache-2.0
//
// exp212 — shell/verdict.h, compiled for this machine and fed made-up runs:
// the LED's three answers, each from the results that must give it. One
// line per case; exit 1 if any answer is wrong. check.sh also breaks
// verdict.h on purpose and expects this to notice.

#include <stdint.h>
#include <stdio.h>

enum kind { KEYGEN, SIGN, SIGN_OTHER };
struct run { uint32_t kind, seed, instret, cycles; uint8_t region[32]; };

#include "verdict.h"

// Three seeds, the schedule gen.py writes: K0 S0 O0 K1 S1 K2 S2. The RTL's
// numbers: 100 for the key generator, 50 for the signer, 40 for the other
// message.
#define N 7
static const struct run RUNS[N] = {
    {KEYGEN, 0, 0, 100, {0}}, {SIGN, 0, 0, 50, {0}}, {SIGN_OTHER, 0, 0, 40, {0}},
    {KEYGEN, 1, 0, 100, {0}}, {SIGN, 1, 0, 50, {0}}, {KEYGEN, 2, 0, 100, {0}}, {SIGN, 2, 0, 50, {0}},
};

static int failures;

static void as_rtl(struct result *r) {
    for (int i = 0; i < N; i++) r[i] = (struct result){0, RUNS[i].cycles};
}

static void expect(const char *what, const struct run *runs, const struct result *r, uint32_t ran, uint32_t want) {
    static const char *name[] = {"fast", "double", "slow"};
    uint32_t got = verdict(runs, r, N, ran);
    if (got == want) {
        printf("PASS  %s: %s\n", name[want], what);
    } else {
        printf("FAIL  %s: %s — said %s\n", name[want], what, got <= 2 ? name[got] : "?");
        failures++;
    }
}

int main(void) {
    struct result r[N];

    as_rtl(r);
    expect("every run as the RTL counted it", RUNS, r, N, SLOW);

    as_rtl(r);
    for (int i = 0; i < N; i++) r[i].cycles += 7 * (RUNS[i].kind + 1);
    expect("every seed alike, but every number off the RTL's", RUNS, r, N, DOUBLE);

    as_rtl(r);
    r[0].cycles += 1, r[3].cycles += 1, r[5].cycles += 1;
    expect("every seed alike, only the key generator off the RTL's", RUNS, r, N, DOUBLE);

    as_rtl(r);
    r[2].cycles += 1;
    expect("every seed alike, only the other message off the RTL's", RUNS, r, N, DOUBLE);

    as_rtl(r);
    r[3].cycles += 1;
    expect("the second seed's key generation one cycle longer", RUNS, r, N, FAST);

    as_rtl(r);
    r[6].cycles -= 1;
    expect("the last seed's signature one cycle shorter", RUNS, r, N, FAST);

    as_rtl(r);
    r[0].cycles += 1;
    expect("the first seed's key generation alone one cycle longer", RUNS, r, N, FAST);

    as_rtl(r);
    r[2].cycles = r[1].cycles;
    expect("the other message as long as the signer's: blind", RUNS, r, N, FAST);

    as_rtl(r);
    r[6].failed = 3;
    expect("the last run's region not the model's", RUNS, r, N, FAST);

    as_rtl(r);
    r[1].failed = 4;
    expect("a run with the wrong minstret", RUNS, r, N, FAST);

    as_rtl(r);
    expect("one run missing", RUNS, r, N - 1, FAST);

    struct run no_other[N];
    for (int i = 0; i < N; i++) no_other[i] = RUNS[i];
    no_other[2].kind = SIGN, no_other[2].cycles = 50;
    as_rtl(r);
    r[2].cycles = 50;
    expect("a schedule with no other message", no_other, r, N, FAST);

    return failures != 0;
}
