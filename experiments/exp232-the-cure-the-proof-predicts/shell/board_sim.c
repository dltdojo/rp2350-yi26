// SPDX-License-Identifier: Apache-2.0
//
// exp232 — the same shell on the Hazard3 RTL: the testbench's print port
// instead of an LED and USB, trng_sim.h's fixed words instead of the TRNG,
// and one batch of six patients instead of forever.
//
//   SRCH tried accepted relapsing answer loophole minstret
//   PLAN the protocol's SHA-256, eight words
//   PTNT n word arm width at model world resistant t24 tissue t64
//   FAIL check got                     a check failed
//   FAUL step cause                    the shell itself trapped

#include "board.h"
#include "fail_sim.h"
#include "trng_sim.h"

void board_init(void) {}

void board_tick(void) {}

void board_searched(const struct search *s, const uint8_t plan[32]) {
    IO_PRINT_U32 = 0x48435253u;   // "SRCH"
    IO_PRINT_U32 = s->tried;
    IO_PRINT_U32 = s->accepted;
    IO_PRINT_U32 = s->relapsing;
    IO_PRINT_U32 = s->answer;
    IO_PRINT_U32 = s->loophole;
    IO_PRINT_U32 = s->instret;
    IO_PRINT_U32 = 0x4e414c50u;   // "PLAN"
    for (uint32_t i = 0; i < 32; i += 4)
        IO_PRINT_U32 = (uint32_t)plan[i] << 24 | (uint32_t)plan[i + 1] << 16 | (uint32_t)plan[i + 2] << 8 | plan[i + 3];
}

void board_patient(const struct search *s, const uint8_t plan[32], const struct patient *p, const struct tally *t) {
    (void)s;
    (void)plan;
    (void)t;
    IO_PRINT_U32 = 0x544e5450u;   // "PTNT"
    IO_PRINT_U32 = p->n;
    IO_PRINT_U32 = p->word;
    IO_PRINT_U32 = p->arm;
    IO_PRINT_U32 = p->width;
    IO_PRINT_U32 = p->at;
    IO_PRINT_U32 = p->model;
    IO_PRINT_U32 = p->world;
    IO_PRINT_U32 = p->resistant;
    IO_PRINT_U32 = p->t24;
    IO_PRINT_U32 = p->tissue;
    IO_PRINT_U32 = p->t64;
    if (p->n == 6) {
        IO_EXIT = 0;
        for (;;) {}
    }
}
