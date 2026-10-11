// SPDX-License-Identifier: Apache-2.0
//
// exp228 — the Pico 2: the shell runs every case, forever, and says over USB
// (tools/hazard3/shell/speak.h) what the kernel halted with for each, while
// the LED gives each case a beat.
//
//   CASE round i code want minstret sigs valid name
//                         one case: the kernel's exit code, script.py's
//                         verdict, minstret, how many signatures the shell
//                         checked for it and how many were valid
//   ROUND round cases     every case as it should be, this round
//
// The beat: a case the script accepts (code 0), on for one unit and off for
// one; a case it rejects, dark for two — 33 beats, about 12 s a round, and
// 1.5 s dark between rounds. The kernel and BIP340 take milliseconds a case:
// this is the pace a person can count, not the computation.
//
// The LED gives the beats unless a host is part way through enumerating the
// device — a stage from 2 (bus reset) to 5 (addressed) — when it shows that
// stage the way exp226 does, for as long as a round would last. A check that
// fails stops it all: speak.h's error, with the check as the count.
//
// Every line goes out only while a page holds the port open (DTR).

#define SPEAK_NAME "exp228"
#define SPEAK_PRODUCT "exp228 the script the kernel runs"
#define SPEAK_SERIAL "228"
#include "speak.h"

static uint32_t stage_shown;   // set in board_case: the shell has no initialised data

void board_case(uint32_t round, uint32_t i, const char *name, uint32_t code, uint32_t want, uint32_t instret,
                uint32_t sigs, uint32_t valid) {
    last_instret = instret;
    lives = round;
    put("CASE");
    put_hex(round);
    put_hex(i);
    put_hex(code);
    put_hex(want);
    put_hex(instret);
    put_hex(sigs);
    put_hex(valid);
    put(" ");
    put(name);
    send();

    if (i == 0) stage_shown = usbdev.stage >= USBDEV_RESET && usbdev.stage < USBDEV_CONFIGURED;
    if (stage_shown) {
        if (i == 0) {
            uint32_t start = csrr(mcycle);
            while (csrr(mcycle) - start < 66 * unit) count(usbdev.stage + 1u, 0);
        }
        return;
    }
    if (code == 0) flash(unit, unit);
    else pwait(2 * unit);
}

void board_round(uint32_t round, uint32_t cases) {
    put("ROUND");
    put_hex(round);
    put_hex(cases);
    send();
    REG(SIO_OUT_CLR) = LED;
    pwait(8 * unit);
}

void board_fail(uint32_t check, uint32_t got) { speak_fail(check, got); }

void board_fault(uint32_t step, uint32_t cause) {
    (void)step;
    (void)cause;
    led_fault();
}
