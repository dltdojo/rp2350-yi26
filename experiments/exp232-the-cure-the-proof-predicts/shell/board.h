// SPDX-License-Identifier: Apache-2.0
// exp232 — what differs between the chip and the RTL: how the search and the
// trial are shown, and where the trial's random words come from.
#pragma once
#include <stdint.h>

#define GENS 64

// What the search found: of `tried` schedules, `accepted` met the endpoint for
// every enrolled width, and of those `relapsing` left a tumour at generation
// 64 in the model. `answer` the fewest doses, `loophole` the first relapsing.
struct search {
    uint32_t tried, accepted, relapsing, answer, loophole, instret;
};

// One patient: drawn from `word`, given the answer if `arm` is 1 and nothing
// if 0. `model` and `world` are the outcomes (0 the endpoint met and the
// tumour gone at 64, 1 met and back by 64, 2 missed): the proved kernel's for
// this patient, and the world's, which has resistance in it. t24, tissue and
// t64 are the world's: tumour cells at 24, the least tissue up to 24, tumour
// cells at 64.
struct patient {
    uint32_t n, word, arm, width, at, model, world, resistant, t24, tissue, t64;
};

// Every patient so far, by arm and by the world's outcome; and how many of the
// treated the model said would be cured.
struct tally {
    uint32_t arm[2], outcome[2][3], predicted[2];
};

void board_init(void);
// Between two runs of the kernel in the search: the USB answered.
void board_tick(void);
// The search is over and the protocol fixed: its SHA-256.
void board_searched(const struct search *s, const uint8_t plan[32]);
// n random words; 0 if there are none.
int board_trng(uint32_t *words, uint32_t n);
// One patient, and where the trial stands.
void board_patient(const struct search *s, const uint8_t plan[32], const struct patient *p, const struct tally *t);
// A check failed: 1 the kernel's bytes, 2 a run that did not HALT 0, 3
// minstret, 4 the search's answer not cure.py's, 10 the world with no
// resistance in it not the proved model, 11 no random words. On the chip,
// that many flashes after a long light, forever.
__attribute__((noreturn)) void board_fail(uint32_t check, uint32_t got);
__attribute__((noreturn)) void board_fault(uint32_t step, uint32_t cause);
