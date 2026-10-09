// SPDX-License-Identifier: Apache-2.0
//
// exp225 — the Pico 2: each generation's centre cell, a beat on the LED.
//
//   alive   a flash: on for one unit, off for one
//   dead    dark for two units
//
// with a unit about 0.18 s (tools/hazard3/shell/led.h): about 92 s a life,
// then a second and a half dark, and the next life from the last generation.
// A failed check is that many flashes and a pause, forever (led.h's count),
// and a trap in the shell the LED on, steady.

#include "board.h"
#include "led.h"

#define CENTRE 16

// led.h's one-bit verdict is not used here; a life is not a verdict.
static void (*const unused_blink)(uint32_t) __attribute__((unused)) = blink;

void board_init(void) { led_init(); }

void board_play(const uint32_t *life, uint32_t round, uint32_t instret) {
    (void)round;
    (void)instret;
    REG(SIO_OUT_CLR) = LED;
    wait(8);
    for (uint32_t g = 0; g < N; g++) {
        if ((life[g] >> CENTRE) & 1) {
            REG(SIO_OUT_SET) = LED;
            wait(1);
            REG(SIO_OUT_CLR) = LED;
            wait(1);
        } else {
            wait(2);
        }
    }
}

void board_fail(uint32_t check, uint32_t got) {
    (void)got;
    led_count(check);
}

void board_fault(uint32_t step, uint32_t cause) {
    (void)step;
    (void)cause;
    led_fault();
}
