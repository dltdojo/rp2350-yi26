// SPDX-License-Identifier: Apache-2.0
//
// exp209 — the Pico 2: its LED is GPIO25, driven through SIO. Every address is
// rp-pac's for the RP235x (RESETS, IO_BANK0, PADS_BANK0, SIO), written out
// rather than pulled in, because this file is all of the chip support there is.
//
// The LED says one bit, in a way nobody can miscount:
//
//   slow blinking   every check passed and minstret matched the RTL
//   fast blinking   something did not
//   on, steady      the shell hung, or trapped itself
//   dark            the shell never ran, or failed before the LED came up
//
// The clock is whatever the bootrom left running; the shell never touches it.
// Slow and fast are 24 to 1 apart, so they cannot be confused whatever it is.

#include "board.h"

#define REG(a) (*(volatile uint32_t *)(a))
#define csrr(name) ({ uint32_t v; __asm__ volatile ("csrr %0, " #name : "=r"(v)); v; })

#define RESETS_RESET_CLR  0x40023000u          // RESETS + 0x3000: atomic clear
#define RESETS_RESET_DONE 0x40020008u
#define RESET_IO_BANK0    (1u << 6)
#define RESET_PADS_BANK0  (1u << 9)
#define GPIO25_CTRL       (0x40028000u + 25 * 8 + 4)
#define GPIO25_PAD        (0x40038000u + 4 + 25 * 4)
#define PAD_ISO           (1u << 8)            // isolation, set at reset
#define PAD_OD            (1u << 7)            // output disable
#define PAD_IE            (1u << 6)
#define FUNCSEL_SIO       5u
#define SIO_OUT_SET       0xd0000018u
#define SIO_OUT_CLR       0xd0000020u
#define SIO_OE_SET        0xd0000038u
#define LED               (1u << 25)
#define UNIT              2000000u    // ~0.18 s at an ~11 MHz ROSC; an assumption, see README

static void wait(uint32_t units) {
    uint32_t start = csrr(mcycle);
    while (csrr(mcycle) - start < units * UNIT) {}
}

__attribute__((noreturn)) static void blink(uint32_t units) {
    for (;;) {
        REG(SIO_OUT_SET) = LED;
        wait(units);
        REG(SIO_OUT_CLR) = LED;
        wait(units);
    }
}

void board_init(void) {
    uint32_t bits = RESET_IO_BANK0 | RESET_PADS_BANK0;
    REG(RESETS_RESET_CLR) = bits;
    while ((REG(RESETS_RESET_DONE) & bits) != bits) {}
    REG(GPIO25_PAD) = (REG(GPIO25_PAD) & ~(PAD_ISO | PAD_OD)) | PAD_IE;
    REG(GPIO25_CTRL) = FUNCSEL_SIO;
    REG(SIO_OE_SET) = LED;
    REG(SIO_OUT_SET) = LED;
}

// The payload's trap left both counters held; the LED's clock is mcycle, so
// let it run again — minstret has already been read.
void board_report(const struct result *r) {
    __asm__ volatile ("csrwi mcountinhibit, 4");
    blink(r->ok ? 12 : 1);
}

// Steady on: a trap in the shell itself. It cannot say which step — the RTL
// build does that — only that it is not a verdict.
void board_fault(uint32_t step, uint32_t cause) {
    (void)step;
    (void)cause;
    REG(SIO_OUT_SET) = LED;
    for (;;) {}
}
