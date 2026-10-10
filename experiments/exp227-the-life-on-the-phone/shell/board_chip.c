// SPDX-License-Identifier: Apache-2.0
//
// exp227 — the Pico 2: exp225's shell and kernel, unchanged, and exp226's USB
// port (tools/hazard3/shell/speak.h), with every generation of every life sent
// to a page that draws it, one a beat, while the LED plays it.
//
//   board_play   a LIFE line (exp226's, as the RTL prints it), a SEED line,
//                then for each of the 256 generations a GEN line and a beat
//                on the LED: the centre cell, exp225's beat
//
//   LIFE round minstret gen1 gen256 centre-column
//   SEED round seed                   what generation 0 was computed from
//   GEN  round g word                 generation g, all 32 cells
//
// The beat is exp225's: alive, on for one unit and off for one; dead, dark for
// two; about 0.36 s a generation, 92 s a life, and 1.5 s dark before each. The
// kernel wrote all 256 generations in 3079 instructions before the first beat:
// this is a replay at the pace a person can watch, not the computation.
//
// The LED plays the life unless a host is part way through enumerating the
// device — a stage from 2 (bus reset) to 5 (addressed) — when it shows that
// stage the way exp226 does, for as long as a life would last. A stage of 1 is
// no host at all, a USB charger, and the life plays: nothing is stuck.
//
// Every line goes out only while a page holds the port open (DTR); the LED
// does not wait for one.

#define SPEAK_NAME "exp227"
#define SPEAK_PRODUCT "exp227 the life on the phone"
#define SPEAK_SERIAL "227"
#include "speak.h"
#include "expect.h"

#define CENTRE 16

static uint32_t seed;   // set in board_play: the shell has no initialised data

void board_play(const uint32_t *life, uint32_t round, uint32_t instret) {
    last_instret = instret;
    REG(SIO_OUT_CLR) = LED;
    if (round == 0) seed = SEED0;

    uint32_t col = 0;
    for (uint32_t g = 0; g < 32; g++) col |= ((life[g] >> CENTRE) & 1) << g;
    put("LIFE");
    put_hex(round);
    put_hex(instret);
    put_hex(life[0]);
    put_hex(life[N - 1]);
    put_hex(col);
    send();
    put("SEED");
    put_hex(round);
    put_hex(seed);
    send();
    lives = round + 1;
    seed = life[N - 1];   // the shell's next seed, too

    if (usbdev.stage >= USBDEV_RESET && usbdev.stage < USBDEV_CONFIGURED) {
        uint32_t start = csrr(mcycle);
        while (csrr(mcycle) - start < N * 2 * unit) count(usbdev.stage + 1u, 0);
        return;
    }

    pwait(8 * unit);
    for (uint32_t g = 0; g < N; g++) {
        put("GEN");
        put_hex(round);
        put_hex(g);
        put_hex(life[g]);
        send();
        if ((life[g] >> CENTRE) & 1) flash(unit, unit);
        else pwait(2 * unit);
    }
}

void board_fail(uint32_t check, uint32_t got) { speak_fail(check, got); }

void board_fault(uint32_t step, uint32_t cause) {
    (void)step;
    (void)cause;
    led_fault();
}
