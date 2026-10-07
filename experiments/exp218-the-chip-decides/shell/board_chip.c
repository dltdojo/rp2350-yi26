// SPDX-License-Identifier: Apache-2.0
//
// exp218 — the Pico 2: PIO0's registers for real, and the verdict on the LED
// (tools/hazard3/shell/led.h):
//
//   slow blinking     every case held what the model says
//   fast blinking     PIO0 never came out of reset
//   N flashes, ...    the cases that did not, each as that many flashes with
//                     a short dark between them, the list ending in a long
//                     dark, and over again
//   on, steady        the shell trapped

#include "board.h"
#include "led.h"

uint32_t rd(uint32_t addr) { return REG(addr); }
void wr(uint32_t addr, uint32_t v) { REG(addr) = v; }

void board_init(void) { led_init(); }

__attribute__((noreturn)) static void blink_list(uint32_t failed) {
    for (;;) {
        for (uint32_t k = 0; k < 32; k++) {
            if (!(failed >> k & 1u)) continue;
            for (uint32_t i = 0; i <= k; i++) {
                REG(SIO_OUT_SET) = LED;
                wait(2);
                REG(SIO_OUT_CLR) = LED;
                wait(2);
            }
            wait(10);
        }
        wait(20);
    }
}

void board_report(uint32_t failed, uint32_t fields_of_first) {
    (void)fields_of_first;
    __asm__ volatile ("csrwi mcountinhibit, 4");
    if (!failed) blink(12);
    blink_list(failed);
}

void board_reset_failed(uint32_t failed_case) {
    (void)failed_case;
    led_verdict(0);
}

void board_fault(uint32_t step, uint32_t cause) {
    (void)step;
    (void)cause;
    led_fault();
}
