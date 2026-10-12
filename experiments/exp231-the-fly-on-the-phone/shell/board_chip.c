// SPDX-License-Identifier: Apache-2.0
//
// exp231 — the Pico 2: the round shell.c ran, shown on the LED and sent to a
// page over exp226's USB port (tools/hazard3/shell/speak.h).
//
//   board_play   a LIFE line (exp227's), a FLY line, a SEED line, then for
//                each of the 256 steps a SEES line and a beat on the LED:
//                what the fly saw
//
//   LIFE round minstret gen1 gen256 centre-column    exp227's line, the life's kernel
//   FLY  round minstret up down                      the fly's kernel: its count, its totals
//   SEED round seed                                  frame 0, what generation 0 grew from
//   SEES round g word up down                        generation g, frame g + 1, and what
//                                                    the fly saw move from the frame before
//
// The beat is exp225's length, one generation in two units, about 0.36 s,
// 92 s a round and 1.5 s dark before each. Seen moving up: on for one unit,
// off for one. Seen not moving: dark for two. Seen moving down: never — the
// shell stopped on check 14 before it got here. So the LED is an even beat,
// with a gap where the fly saw nothing move: the first step of the first
// round, from one live cell, is the only one in the first dozen rounds.
//
// The LED shows the round unless a host is part way through enumerating the
// device — a stage from 2 (bus reset) to 5 (addressed) — when it shows that
// stage the way exp226 does, for as long as a round would last. A stage of 1
// is no host at all, a USB charger, and the round plays: nothing is stuck.
//
// Every line goes out only while a page holds the port open (DTR); the LED
// does not wait for one. Both kernels ran before the first beat, in about
// 1.6 ms at 48 MHz: this is a replay at the pace a person can watch.

#define SPEAK_NAME "exp231"
#define SPEAK_PRODUCT "exp231 the fly on the phone"
#define SPEAK_SERIAL "231"
#include "speak.h"

#define CENTRE 16

void board_play(const struct round *r) {
    last_instret = r->fly_instret;
    REG(SIO_OUT_CLR) = LED;

    uint32_t col = 0;
    for (uint32_t g = 0; g < 32; g++) col |= ((r->life[g] >> CENTRE) & 1) << g;
    put("LIFE");
    put_hex(r->round);
    put_hex(r->instret);
    put_hex(r->life[0]);
    put_hex(r->life[N - 1]);
    put_hex(col);
    send();
    put("FLY");
    put_hex(r->round);
    put_hex(r->fly_instret);
    put_hex(r->up);
    put_hex(r->down);
    send();
    put("SEED");
    put_hex(r->round);
    put_hex(r->seed);
    send();
    lives = r->round + 1;

    if (usbdev.stage >= USBDEV_RESET && usbdev.stage < USBDEV_CONFIGURED) {
        uint32_t start = csrr(mcycle);
        while (csrr(mcycle) - start < N * 2 * unit) count(usbdev.stage + 1u, 0);
        return;
    }

    pwait(8 * unit);
    for (uint32_t g = 0; g < N; g++) {
        uint32_t up = r->steps[2 * g], down = r->steps[2 * g + 1];
        put("SEES");
        put_hex(r->round);
        put_hex(g);
        put_hex(r->life[g]);
        put_hex(up);
        put_hex(down);
        send();
        if (up > down) flash(unit, unit);
        else pwait(2 * unit);
    }
}

void board_fail(uint32_t check, uint32_t got) { speak_fail(check, got); }

void board_fault(uint32_t step, uint32_t cause) {
    (void)step;
    (void)cause;
    led_fault();
}
