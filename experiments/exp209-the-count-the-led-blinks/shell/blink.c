// SPDX-License-Identifier: Apache-2.0
//
// exp209 — the LED's language. With no UART and no USB, this is the only way
// anything leaves the board, so every pattern means one thing and none needs
// a stopwatch: a person counts flashes, never times them.
//
//   PASS        one long glow                      ▬▬▬▬▬▬▬▬▬▬
//   FAIL k      k long flashes: check k failed      ▬▬▬▬  ▬▬▬▬
//   FAULT       fast flicker: the shell itself       ▪▪▪▪▪▪▪▪▪▪▪▪
//               trapped
//
// then a pause, then a number as groups of short blinks, one group per decimal
// digit, most significant first, ten blinks for a zero; then a long dark gap,
// and the round repeats. After PASS or FAIL the number is minstret (or, when
// check 3 failed, mcause); after FAULT it is the step that did not come back.
//
// Times are in units; the chip's unit is a fixed number of cycles of a clock
// the shell never sets, so its length is approximate and nothing depends on it.

#include "blink.h"

enum { DOT_ON = 3, DOT_OFF = 3, DIGIT_GAP = 7, DASH_ON = 12, DASH_OFF = 6,
       GLOW = 30, PAUSE = 14, END = 30, FLICKER = 30 };

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

void blink_report(led_hold hold, uint32_t failed, uint32_t n) {
    if (failed == 0) {
        hold(1, GLOW);
    } else {
        for (uint32_t i = 0; i < failed; i++) {
            hold(1, DASH_ON);
            hold(0, DASH_OFF);
        }
    }
    hold(0, PAUSE);
    number(hold, n);
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
