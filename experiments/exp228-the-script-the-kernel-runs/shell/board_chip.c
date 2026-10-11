// SPDX-License-Identifier: Apache-2.0
//
// exp228 — the Pico 2: the shell runs every case, forever, and says over USB
// (tools/hazard3/shell/speak.h) what the kernel halted with for each, while
// the LED blinks slowly to say that nothing has failed.
//
//   CASE round i code want minstret sigs valid name
//                         one case: the kernel's exit code, script.py's
//                         verdict, minstret, how many signatures the shell
//                         checked for it and how many were valid
//   ROUND round cases     every case as it should be, this round
//
// Each case takes two units, about 0.36 s, so that a person can read the
// lines as they come; a round is 33 cases and three slots more.
//
// The LED: on for three cases' worth and off for three, about 1 s each, the
// whole time, whatever the cases' verdicts — revision 1 gave an accepted case
// a flash and a rejected one a dark beat, and a person could not tell that
// apart from anything else. The verdicts are the USB lines' to say. So:
//
//   a slow, even blink           running, and every check has held
//   2 s on, then N flashes       check N failed (speak.h's error), and it stopped
//   N flashes, 3 s dark          a host part way through enumerating: stage N
//                                (2 bus reset to 5 addressed), as in exp226
//   lit or dark, and staying so  the shell died
//
// The blink holds still while the shell checks a signature, a fraction of a
// second, so it is even rather than exact.
//
// Every line goes out only while a page holds the port open (DTR).

#define SPEAK_NAME "exp228"
#define SPEAK_PRODUCT "exp228 the script the kernel runs"
#define SPEAK_SERIAL "228"
#include "speak.h"

static uint32_t stage_shown;   // set in board_case: the shell has no initialised data
static uint32_t slots;         // two units each, from zero

// One slot of the slow blink: three on, three off.
static void slot(void) {
    if ((slots++ / 3) & 1) REG(SIO_OUT_CLR) = LED;
    else REG(SIO_OUT_SET) = LED;
    pwait(2 * unit);
}

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
    (void)code;
    slot();
}

void board_round(uint32_t round, uint32_t cases) {
    put("ROUND");
    put_hex(round);
    put_hex(cases);
    send();
    for (int k = 0; k < 3; k++) slot();
}

void board_fail(uint32_t check, uint32_t got) { speak_fail(check, got); }

void board_fault(uint32_t step, uint32_t cause) {
    (void)step;
    (void)cause;
    led_fault();
}
