// SPDX-License-Identifier: Apache-2.0
//
// exp216 — the same shell on the Hazard3 RTL, which has no PIO and no GPIO.
// Every write is printed instead of made, for check.sh to hold to
// expected.txt; every read is answered by a stand-in chosen with -DDEVICE=:
//
//   0  a PIO that works: out of reset, each command answered, the pin at the
//      level last commanded
//   1  one that never comes out of reset
//   2  one that never answers
//   3  one that answers the second command with something else
//   4  one whose pin stays at SIO's level, 1, whatever it is told
//   5  one whose pin stays at 0
//   6  one whose RX FIFO still holds a word at the end
//
// Not a model of PIO or of a pad: it says nothing about the chip. The RTL run
// shows that the shell writes what it should and reads its answers as it
// should.
//
//   WRIT addr value        a register write
//   REPT verdict command   the shell's result: which command, 0 to 7
//   FAUL step cause        the shell itself trapped

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
        uint32_t f = FSTAT_SM0_TXEMPTY;
        if (!pending || DEVICE == 2) f |= FSTAT_SM0_RXEMPTY;
        if (DEVICE == 6 && sent == 8) f &= ~FSTAT_SM0_RXEMPTY;
        return f;
    }
    case PIO_RXF0:
        pending = 0;
        return (DEVICE == 3 && sent == 2) ? last_tx ^ 1u : last_tx;
    case SIO_GPIO_IN: {
        uint32_t pin = DEVICE == 4 ? 1u : DEVICE == 5 ? 0u : (last_tx != 0);
        return pin << 25;
    }
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

void board_report(uint32_t verdict, uint32_t command) {
    IO_PRINT_U32 = 0x52455054u;   // "REPT"
    IO_PRINT_U32 = verdict;
    IO_PRINT_U32 = command;
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
