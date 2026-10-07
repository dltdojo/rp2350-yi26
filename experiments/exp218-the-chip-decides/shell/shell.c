// SPDX-License-Identifier: Apache-2.0
//
// exp218 — the shell: each of model/Cases.lean's cases on PIO0's state
// machine 0, and what the chip holds when it stops, against what
// lean/Pio/Machine.lean says it holds.
//
// Once: GPIO2..9's pads pulled up or down as Cases.lean's EXT says, input
// enabled, output disabled, isolation off, and handed to PIO0. Nothing
// drives them: a case that reads pins reads the pulls.
//
// For each case:
//   1. PIO0 through reset, so nothing carries over from the case before;
//   2. its words into instruction memory, the rest of it 0 (`jmp 0`, as the
//      model reads an unloaded word); EXECCTRL, SHIFTCTRL and PINCTRL; the
//      state machine restarted and sent to where the case starts;
//   3. the first batch into TX; enabled; left to run until it has stopped;
//      disabled; what RX holds taken;
//   4. the second batch into TX; enabled, left to stop, disabled again;
//   5. read: its pc (SM0_ADDR), the IRQ flags, the pin values and output
//      enables it drives (DBG_PADOUT, DBG_PADOE), the TX level, what RX
//      holds; then, by instructions executed on the stopped machine through
//      SM0_INSTR, ISR (`push noblock`), and X, Y and OSR (`mov isr, …` then
//      `push noblock`) — the shift counts cannot be read, and are not;
//   6. each of those against the model's, and the case marked if any differs.
//
// Every case runs whatever the one before it said, and the verdict names
// all that disagreed. A step counter is written before each step, for the
// RTL build to name the step a trap came from.

#include <stdint.h>

#include "board.h"
#include "cases.h"
#include "pio.h"

#define csrr(name) ({ uint32_t v; __asm__ volatile ("csrr %0, " #name : "=r"(v)); v; })
#define PATIENCE 1000000u      // mcycle ticks to wait for one word: ~0.1 s at ~11 MHz
#ifndef SETTLE
#define SETTLE 200000u         // and for a case to stop: ~20 ms, against tens of PIO cycles
#endif
#define PIN_FIRST 2u
#define PIN_LAST  9u

static volatile uint32_t step;

static void pause(uint32_t ticks) {
    uint32_t start = csrr(mcycle);
    while (csrr(mcycle) - start < ticks) {}
}

static int wait_for(uint32_t addr, uint32_t mask, uint32_t want) {
    uint32_t start = csrr(mcycle);
    while ((rd(addr) & mask) != want)
        if (csrr(mcycle) - start > PATIENCE) return 0;
    return 1;
}

// What RX holds, up to five words: a fifth would be one the model never put
// there.
static uint32_t drain(uint32_t *out) {
    uint32_t n = 0;
    while (n < 5 && !(rd(PIO_FSTAT) & FSTAT_SM0_RXEMPTY)) out[n++] = rd(PIO_RXF0);
    return n;
}

// One word out of the stopped machine: `mov isr, src` unless src is ISR
// itself, then `push noblock`. 0 if it never arrives, which also marks the
// case.
static uint32_t pull_out(uint32_t mov, int *lost) {
    if (mov) wr(PIO_SM0_INSTR, mov);
    wr(PIO_SM0_INSTR, I_PUSH);
    if (!wait_for(PIO_FSTAT, FSTAT_SM0_RXEMPTY, 0)) { *lost = 1; return 0; }
    return rd(PIO_RXF0);
}

static int same_list(uint32_t n, const uint32_t *got, uint32_t want_n, const uint32_t *want) {
    if (n != want_n) return 0;
    for (uint32_t i = 0; i < n; i++)
        if (got[i] != want[i]) return 0;
    return 1;
}

// Which of what was read differs: bit 0 pc, 1 X, 2 Y, 3 ISR, 4 OSR, 5 IRQ,
// 6 pins, 7 directions, 8 TX level, 9 RX at the first stop, 10 at the
// second, 11 a word that never came out.
static uint32_t run_case(const struct pio_case *c) {
    step = 10;
    wr(RESETS_RESET_SET, RESET_PIO0);
    wr(RESETS_RESET_CLR, RESET_PIO0);
    if (!wait_for(RESETS_RESET_DONE, RESET_PIO0, RESET_PIO0)) return ~0u;

    step = 11;
    for (uint32_t i = 0; i < 32; i++) wr(PIO_INSTR_MEM(i), i < c->len ? c->words[i] : 0u);
    wr(PIO_SM0_EXECCTRL, c->execctrl);
    wr(PIO_SM0_SHIFTCTRL, c->shiftctrl);
    wr(PIO_SM0_PINCTRL, c->pinctrl);
    wr(PIO_CTRL, CTRL_SM0_RESTART | CTRL_SM0_CLKDIV_RESTART);
    wr(PIO_SM0_INSTR, c->jmp);

    step = 12;
    uint32_t rx1[5], rx2[5];
    for (uint32_t i = 0; i < c->ntx1; i++) wr(PIO_TXF0, c->tx1[i]);
    wr(PIO_CTRL, CTRL_SM0_ENABLE);
    pause(SETTLE);
    wr(PIO_CTRL, 0);
    uint32_t n1 = drain(rx1);

    step = 13;
    for (uint32_t i = 0; i < c->ntx2; i++) wr(PIO_TXF0, c->tx2[i]);
    wr(PIO_CTRL, CTRL_SM0_ENABLE);
    pause(SETTLE);
    wr(PIO_CTRL, 0);

    step = 14;
    const struct pio_want *w = &c->want;
    uint32_t pc = rd(PIO_SM0_ADDR), irq = rd(PIO_IRQ) & 0xffu;
    uint32_t padout = rd(PIO_DBG_PADOUT), padoe = rd(PIO_DBG_PADOE);
    uint32_t txlevel = rd(PIO_FLEVEL) & 0xfu;
    uint32_t n2 = drain(rx2);
    int lost = 0;
    uint32_t isr = pull_out(0, &lost);
    uint32_t x = pull_out(I_MOV_ISR_X, &lost);
    uint32_t y = pull_out(I_MOV_ISR_Y, &lost);
    uint32_t osr = pull_out(I_MOV_ISR_OSR, &lost);

    step = 15;
    uint32_t differ = 0;
    if (pc != w->pc) differ |= 1u << 0;
    if (x != w->x) differ |= 1u << 1;
    if (y != w->y) differ |= 1u << 2;
    if (isr != w->isr) differ |= 1u << 3;
    if (osr != w->osr) differ |= 1u << 4;
    if (irq != w->irq) differ |= 1u << 5;
    if (padout != w->padout) differ |= 1u << 6;
    if (padoe != w->padoe) differ |= 1u << 7;
    if (txlevel != w->txlevel) differ |= 1u << 8;
    if (!same_list(n1, rx1, w->nrx1, w->rx1)) differ |= 1u << 9;
    if (!same_list(n2, rx2, w->nrx2, w->rx2)) differ |= 1u << 10;
    if (lost) differ |= 1u << 11;
    return differ;
}

void shell_main(void) {
    step = 1;
    // Hazard3 comes out of reset with mcycle held; every wait below counts it.
    __asm__ volatile ("csrwi mcountinhibit, 4");
    board_init();

    step = 2;
    for (uint32_t p = PIN_FIRST; p <= PIN_LAST; p++) {
        uint32_t pull = (EXT_PULLED_UP >> p) & 1u ? PADS_PUE : PADS_PDE;
        wr(GPIO_PAD(p), PADS_OD | PADS_IE | PADS_DRIVE_4MA | pull | PADS_SCHMITT);
        wr(GPIO_CTRL(p), FUNCSEL_PIO0);
    }

    uint32_t failed = 0, first = 0;
    for (uint32_t k = 0; k < NCASES; k++) {
        uint32_t differ = run_case(&CASES[k]);
        if (differ == ~0u) board_reset_failed(k);
        if (differ) {
            if (!failed) first = differ;
            failed |= 1u << k;
        }
    }
    step = 3;
    wr(PIO_CTRL, 0);
    board_report(failed, first);
}

// Every trap is the shell's own: there is no payload.
void handle(uint32_t *x) {
    (void)x;
    board_fault(step, csrr(mcause));
}
