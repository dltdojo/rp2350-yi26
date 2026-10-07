// SPDX-License-Identifier: Apache-2.0
//
// exp214 — the shell: bring PIO0 out of reset, load invert.pio into its
// instruction memory, start state machine 0 at instruction 0, and hand it
// eight words one at a time. Each must come back through the RX FIFO as its
// bitwise complement. Then both FIFOs must be empty.
//
// No payload runs; tools/hazard3/harness/harness.S is linked in only because
// the shell's start code sends every trap to `handle`, which here is always a
// fault in the shell itself. A step counter is written before each step, so
// the RTL build can name the step a trap came from.

#include <stdint.h>

#include "board.h"
#include "pio.h"
#include "program.h"

#define csrr(name) ({ uint32_t v; __asm__ volatile ("csrr %0, " #name : "=r"(v)); v; })
#define PATIENCE 1000000u      // mcycle ticks to wait for any one thing: ~0.1 s at ~11 MHz

static const uint32_t WORDS[8] = {
    0x00000000u, 0xffffffffu, 0x12345678u, 0x80000001u,
    0x55555555u, 0xaaaaaaaau, 0x0000ffffu, 0xdeadbeefu,
};

static volatile uint32_t step;

// Wait until (rd(addr) & mask) == want; 0 if PATIENCE ran out first.
static int wait_for(uint32_t addr, uint32_t mask, uint32_t want) {
    uint32_t start = csrr(mcycle);
    while ((rd(addr) & mask) != want)
        if (csrr(mcycle) - start > PATIENCE) return 0;
    return 1;
}

void shell_main(void) {
    step = 1;
    // Every wait below is timed by mcycle, and Hazard3 comes out of reset with
    // it held (mcountinhibit.CY): let it run, as led.h does for its blinking.
    __asm__ volatile ("csrwi mcountinhibit, 4");
    board_init();

    step = 2;
    wr(RESETS_RESET_CLR, RESET_PIO0);
    if (!wait_for(RESETS_RESET_DONE, RESET_PIO0, RESET_PIO0)) board_report(V_RESET, 0);

    step = 3;
    for (uint32_t i = 0; i < PROGRAM_LEN; i++) wr(PIO_INSTR_MEM(i), PROGRAM[i]);
    wr(PIO_SM0_EXECCTRL, EXECCTRL_WRAP(0, PROGRAM_LEN - 1));
    wr(PIO_CTRL, CTRL_SM0_RESTART | CTRL_SM0_CLKDIV_RESTART);
    wr(PIO_SM0_INSTR, JMP_0);
    wr(PIO_CTRL, CTRL_SM0_ENABLE);

    step = 4;
    for (uint32_t i = 0; i < 8; i++) {
        uint32_t w = WORDS[i];
        if (!wait_for(PIO_FSTAT, FSTAT_SM0_TXFULL, 0)) board_report(V_SILENT, w);
        wr(PIO_TXF0, w);
        if (!wait_for(PIO_FSTAT, FSTAT_SM0_RXEMPTY, 0)) board_report(V_SILENT, w);
        uint32_t r = rd(PIO_RXF0);
        if (r == w) board_report(V_ECHO, w);
        if (r != ~w) board_report(V_WRONG, w);
    }

    step = 5;
    uint32_t f = rd(PIO_FSTAT);
    if ((f & (FSTAT_SM0_RXEMPTY | FSTAT_SM0_TXEMPTY)) != (FSTAT_SM0_RXEMPTY | FSTAT_SM0_TXEMPTY))
        board_report(V_LEFTOVER, f);
    wr(PIO_CTRL, 0);
    board_report(V_OK, 0);
}

// Every trap is the shell's own: there is no payload.
void handle(uint32_t *x) {
    (void)x;
    board_fault(step, csrr(mcause));
}
