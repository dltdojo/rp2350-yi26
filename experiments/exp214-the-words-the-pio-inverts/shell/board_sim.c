// SPDX-License-Identifier: Apache-2.0
//
// exp214 — the same shell on the Hazard3 RTL, which has no PIO. Every write
// the shell makes is printed instead of made, so check.sh can hold the order
// and the values to what the datasheet asks for; every read is answered by a
// stand-in, chosen at build time with -DDEVICE=, so check.sh can hold the
// shell's verdicts to what each kind of failure should give:
//
//   0  a PIO that works: out of reset, room in TX, each word back complemented
//   1  one that never comes out of reset
//   2  one that never answers
//   3  one that hands each word back as it was
//   4  one that answers the last word wrongly
//   5  one whose RX FIFO still holds a word at the end
//
// The stand-in is not a model of PIO; it says nothing about the chip. What the
// RTL run shows is that the shell writes what it should and reads its answers
// the way it should.
//
//   WRIT addr value      a register write
//   REPT verdict word    the shell's result
//   FAUL step cause      the shell itself trapped

#include "board.h"
#include "pio.h"

#ifndef DEVICE
#define DEVICE 0
#endif

#define IO_PRINT_U32 (*(volatile uint32_t *)0xc0000004u)
#define IO_EXIT      (*(volatile uint32_t *)0xc0000008u)

static uint32_t last_tx, sent, pending;

uint32_t rd(uint32_t addr) {
    switch (addr) {
    case RESETS_RESET_DONE:
        return DEVICE == 1 ? 0 : RESET_PIO0;
    case PIO_FSTAT: {
        uint32_t f = 0;
        if (!pending) f |= FSTAT_SM0_RXEMPTY;
        f |= FSTAT_SM0_TXEMPTY;
        if (DEVICE == 2) f |= FSTAT_SM0_RXEMPTY;
        if (DEVICE == 5 && sent == 8) f &= ~FSTAT_SM0_RXEMPTY;
        return f;
    }
    case PIO_RXF0:
        pending = 0;
        if (DEVICE == 3) return last_tx;
        if (DEVICE == 4 && sent == 8) return ~last_tx ^ 1u;
        return ~last_tx;
    default:
        return 0;
    }
}

void wr(uint32_t addr, uint32_t v) {
    IO_PRINT_U32 = 0x57524954u;   // "WRIT"
    IO_PRINT_U32 = addr;
    IO_PRINT_U32 = v;
    if (addr == PIO_TXF0) { last_tx = v; sent++; pending = 1; }
}

void board_init(void) {}

void board_report(uint32_t verdict, uint32_t word) {
    IO_PRINT_U32 = 0x52455054u;   // "REPT"
    IO_PRINT_U32 = verdict;
    IO_PRINT_U32 = word;
    IO_EXIT = verdict;
    for (;;) {}
}

void board_fault(uint32_t step, uint32_t cause) {
    IO_PRINT_U32 = 0x4641554cu;   // "FAUL"
    IO_PRINT_U32 = step;
    IO_PRINT_U32 = cause;
    IO_EXIT = 100;
    for (;;) {}
}
