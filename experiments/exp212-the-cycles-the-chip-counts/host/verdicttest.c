// SPDX-License-Identifier: Apache-2.0
//
// exp212 — shell/verdict.h, compiled for this machine and fed made-up runs:
// each of the LED's answers, from the results that must give it. One line
// per case; exit 1 if any answer is wrong. check.sh also breaks verdict.h on
// purpose and expects this to notice.

#include <stdint.h>
#include <stdio.h>

enum kind { KEYGEN, SIGN, SIGN_OTHER, KEYGEN_WARM };
struct run { uint32_t kind, seed, instret, cycles, hashes; uint8_t region[32]; };

#include "verdict.h"

// Three seeds, the schedule gen.py writes: W0 K0 S0 O0 K1 S1 K2 S2, W0 the
// warm-up. Each kind's minstret, RTL mcycle and HASH calls are the real
// ones, so the arithmetic is done at the size the chip does it.
#define KG 145191u, 195653u, 17183u
#define SG 5915u, 7600u, 547u
#define OT 5705u, 7314u, 517u
#define N 8
static const struct run RUNS[N] = {
    {KEYGEN_WARM, 0, KG, {0}},
    {KEYGEN, 0, KG, {0}}, {SIGN, 0, SG, {0}}, {SIGN_OTHER, 0, OT, {0}},
    {KEYGEN, 1, KG, {0}}, {SIGN, 1, SG, {0}}, {KEYGEN, 2, KG, {0}}, {SIGN, 2, SG, {0}},
};

static int failures;

// Every run at the RTL's cycles plus a + c·S + b·minstret, the same for
// every seed of a kind.
static void silicon(struct result *r, int64_t a, int64_t c, int64_t b) {
    for (int i = 0; i < N; i++)
        r[i] = (struct result){0, (uint32_t)(RUNS[i].cycles + a + c * RUNS[i].hashes + b * RUNS[i].instret)};
}

static void expect(const char *what, const struct run *runs, const struct result *r, uint32_t ran, uint32_t want) {
    static const char *name[] = {"slow", "1 flash", "2 flashes", "3 flashes", "4 flashes", "5 flashes", "6 flashes"};
    uint32_t got = verdict(runs, r, N, ran);
    if (got == want) {
        printf("PASS  %s: %s\n", name[want], what);
    } else {
        printf("FAIL  %s: %s — said %s\n", name[want], what, got <= 6 ? name[got] : "?");
        failures++;
    }
}

int main(void) {
    struct result r[N];

    silicon(r, 0, 0, 0);
    expect("every run as the RTL counted it", RUNS, r, N, V_SLOW);

    silicon(r, 0, 0, 0);
    r[0].cycles += 40;
    expect("the warm-up alone long: the cold shell, as revision 2 saw", RUNS, r, N, V_SLOW);

    silicon(r, 0, 3, 0);
    expect("3 more cycles for every HASH call", RUNS, r, N, V_PER_HASH);

    silicon(r, 11, 3, 0);
    r[0].cycles += 40;
    expect("11 more per run and 3 per HASH call, the warm-up longer still", RUNS, r, N, V_PER_HASH);

    silicon(r, -2, -1, 0);
    expect("fewer, 2 per run and 1 per HASH call", RUNS, r, N, V_PER_HASH);

    silicon(r, 0, 0, 1);
    expect("1 more cycle for every instruction", RUNS, r, N, V_PER_INSN);

    silicon(r, 5, 0, 2);
    expect("5 more per run and 2 per instruction", RUNS, r, N, V_PER_INSN);

    silicon(r, 7, 0, 0);
    expect("7 more cycles on every run, whatever it did", RUNS, r, N, V_OFFSET);

    silicon(r, 0, 3, 0);
    r[1].cycles += 1, r[4].cycles += 1, r[6].cycles += 1;
    expect("3 per HASH call, and one more on every key generation: on no line", RUNS, r, N, V_NEITHER);

    silicon(r, 0, 3, 1);
    expect("3 per HASH call and 1 per instruction: on neither line alone", RUNS, r, N, V_NEITHER);

    silicon(r, 0, 3, 0);
    r[6].cycles += 1;
    expect("the last seed's key generation one cycle longer", RUNS, r, N, V_SEEDS);

    silicon(r, 0, 3, 0);
    r[7].cycles -= 1;
    expect("the last seed's signature one cycle shorter", RUNS, r, N, V_SEEDS);

    silicon(r, 0, 3, 0);
    r[1].cycles += 1;
    expect("seed 0's timed key generation alone one cycle longer", RUNS, r, N, V_SEEDS);

    silicon(r, 0, 0, 0);
    r[3].cycles = r[2].cycles;
    expect("the other message as long as the signer's: blind", RUNS, r, N, V_SEEDS);

    silicon(r, 0, 3, 0);
    r[7].failed = 3;
    expect("the last run's region not the model's", RUNS, r, N, V_CHECK);

    silicon(r, 0, 3, 0);
    r[0].failed = 3;
    expect("the warm-up's region not the model's", RUNS, r, N, V_CHECK);

    silicon(r, 0, 3, 0);
    expect("one run missing", RUNS, r, N - 1, V_CHECK);

    struct run no_other[N];
    for (int i = 0; i < N; i++) no_other[i] = RUNS[i];
    no_other[3] = (struct run){SIGN, 0, SG, {0}};
    silicon(r, 0, 0, 0);
    r[3].cycles = 7600;
    expect("a schedule with no other message", no_other, r, N, V_CHECK);

    return failures != 0;
}
