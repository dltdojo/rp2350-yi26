// SPDX-License-Identifier: Apache-2.0
//
// exp209 — the LED's language. With no UART and no USB, this is the only way
// anything leaves the board, so every pattern means one thing and none needs
// a stopwatch: a person counts flashes, never times them.
//
// A report is a round of numbers. Number i is announced by i long flashes,
// then comes as groups of short blinks, one group per decimal digit, most
// significant first, ten blinks for a zero. A long dark gap ends the round,
// and it repeats forever:
//
//   ▬ ··· ▬▬ ··· ▬▬▬ ··· ▬▬▬▬ ···        (dark)        ▬ ···
//
// so a person who starts watching mid-round can tell where they are by
// counting the long flashes before the number they are reading.
//
// A fault — the shell itself trapped — is a fast flicker, never a long flash,
// then the step it was in, as digits.
//
// Revision 1 announced PASS with a glow and FAIL k with k flashes, and blinked
// one number; on the board that read "2 long flashes, 1-0-8". Revision 2 says
// every number there is to say instead of only the first failure.
//
// Times are in units; the chip's unit is a fixed number of cycles of a clock
// the shell never sets, so its length is approximate and nothing depends on it.

#include "blink.h"

enum { DOT_ON = 3, DOT_OFF = 3, DIGIT_GAP = 7, DASH_ON = 12, DASH_OFF = 6,
       PAUSE = 14, END = 40, FLICKER = 30 };

static void digit(led_hold hold, uint32_t d) {
    for (uint32_t i = 0; i < (d == 0 ? 10 : d); i++) {
        hold(1, DOT_ON);
        hold(0, DOT_OFF);
    }
    hold(0, DIGIT_GAP);
}

static void number(led_hold hold, uint32_t n) {
    uint32_t div = 1;
    while (n / div >= 10) div *= 10;
    for (; div; div /= 10) digit(hold, n / div % 10);
}

void blink_report(led_hold hold, const uint32_t *numbers, uint32_t n) {
    for (uint32_t i = 0; i < n; i++) {
        for (uint32_t f = 0; f <= i; f++) {
            hold(1, DASH_ON);
            hold(0, DASH_OFF);
        }
        hold(0, PAUSE);
        number(hold, numbers[i]);
        hold(0, PAUSE);
    }
    hold(0, END);
}

void blink_fault(led_hold hold, uint32_t step) {
    for (uint32_t i = 0; i < FLICKER; i++) {
        hold(1, 1);
        hold(0, 1);
    }
    hold(0, PAUSE);
    number(hold, step);
    hold(0, END);
}
