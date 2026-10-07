// SPDX-License-Identifier: Apache-2.0
//
// exp216 — the shell: PIO0 drives the LED's pin, GPIO25, and the CPU reads
// the pin back.
//
// board_init leaves the LED on, with SIO driving GPIO25 high. Then: PIO0 out
// of reset; the program (proof/Program.lean's, through Lean's encode) into its
// instruction memory; SET pins mapped to GPIO25; GPIO25's function handed to
// PIO0; state machine 0 started at instruction 0. Eight commands follow, each
// a word through TX: the program sets the pin to 0 or 1 and answers through
// RX, and the CPU reads GPIO25 at the pad through SIO's GPIO_IN. SIO's own
// output for the pin stays high throughout, so a pin that reads 0 when told 0
// is one PIO is driving. At the end the pin goes back to SIO, for the LED to
// tell the verdict.
//
// A step counter is written before each step, for the RTL build to name the
// step a trap came from.

#include <stdint.h>

#include "board.h"
#include "pio.h"
#include "program.h"

#define csrr(name) ({ uint32_t v; __asm__ volatile ("csrr %0, " #name : "=r"(v)); v; })
#define PATIENCE 1000000u      // mcycle ticks to wait for any one thing: ~0.1 s at ~11 MHz
#define PIN 25u

static const uint32_t COMMANDS[8] = {0, 1, 1, 0, 1, 0, 0, 1};

static volatile uint32_t step;

static int wait_for(uint32_t addr, uint32_t mask, uint32_t want) {
    uint32_t start = csrr(mcycle);
    while ((rd(addr) & mask) != want)
        if (csrr(mcycle) - start > PATIENCE) return 0;
    return 1;
}

void shell_main(void) {
    step = 1;
    // Hazard3 comes out of reset with mcycle held; every wait below counts it.
    __asm__ volatile ("csrwi mcountinhibit, 4");
    board_init();

    step = 2;
    wr(RESETS_RESET_CLR, RESET_PIO0);
    if (!wait_for(RESETS_RESET_DONE, RESET_PIO0, RESET_PIO0)) board_report(V_RESET, 0);

    step = 3;
    for (uint32_t i = 0; i < PROGRAM_LEN; i++) wr(PIO_INSTR_MEM(i), PROGRAM[i]);
    wr(PIO_SM0_EXECCTRL, EXECCTRL_WRAP(WRAP_BOTTOM, WRAP_TOP));
    wr(PIO_SM0_PINCTRL, PINCTRL_SET(PIN, 1));
    wr(GPIO_CTRL(PIN), FUNCSEL_PIO0);
    wr(PIO_CTRL, CTRL_SM0_RESTART | CTRL_SM0_CLKDIV_RESTART);
    wr(PIO_SM0_INSTR, JMP_0);
    wr(PIO_CTRL, CTRL_SM0_ENABLE);

    step = 4;
    for (uint32_t i = 0; i < 8; i++) {
        uint32_t c = COMMANDS[i];
        if (!wait_for(PIO_FSTAT, FSTAT_SM0_TXFULL, 0)) board_report(V_SILENT, i);
        wr(PIO_TXF0, c);
        if (!wait_for(PIO_FSTAT, FSTAT_SM0_RXEMPTY, 0)) board_report(V_SILENT, i);
        if (rd(PIO_RXF0) != c) board_report(V_ANSWER, i);
        uint32_t pin = (rd(SIO_GPIO_IN) >> PIN) & 1u;
        if (pin != c) board_report(c ? V_PIN : V_SIO, i);
    }

    step = 5;
    uint32_t f = rd(PIO_FSTAT);
    if ((f & (FSTAT_SM0_RXEMPTY | FSTAT_SM0_TXEMPTY)) != (FSTAT_SM0_RXEMPTY | FSTAT_SM0_TXEMPTY))
        board_report(V_LEFTOVER, f);
    wr(PIO_CTRL, 0);
    wr(GPIO_CTRL(PIN), FUNCSEL_SIO);
    board_report(V_OK, 0);
}

// Every trap is the shell's own: there is no payload.
void handle(uint32_t *x) {
    (void)x;
    board_fault(step, csrr(mcause));
}
