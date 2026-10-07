// SPDX-License-Identifier: Apache-2.0
//
// exp219 — the same shell on the Hazard3 RTL. The kernel runs for real there,
// as in exp209; the RTL has no PIO, so its reads are answered by a stand-in
// chosen with -DDEVICE=:
//
//   0  a PIO that works: out of reset, waiting, each word back complemented
//   1  one that never comes out of reset
//   2  one already holding a word in RX before the kernel runs
//   3  one that never answers
//   4  one that hands each word back as it was
//   5  one whose RX still holds a word at the end
//
// Not a model of PIO: it shows that the shell takes each verdict where it
// should.
//
//   REPT verdict failed minstret a0 cause word    the shell's result
//   FAUL step cause                               the shell itself trapped

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
        if (!pending || DEVICE == 3) f |= FSTAT_SM0_RXEMPTY;
        if (DEVICE == 2 && sent == 0) f &= ~FSTAT_SM0_RXEMPTY;
        if (DEVICE == 5 && sent == 16) f &= ~FSTAT_SM0_RXEMPTY;
        return f;
    }
    case PIO_RXF0:
        pending = 0;
        return DEVICE == 4 ? last_tx : ~last_tx;
    default:
        return 0;
    }
}

void wr(uint32_t addr, uint32_t v) {
    if (addr == PIO_TXF0) { last_tx = v; sent++; pending = 1; }
}

void board_init(void) {}

void board_report(const struct result *r) {
    IO_PRINT_U32 = 0x52455054u;   // "REPT"
    IO_PRINT_U32 = r->verdict;
    IO_PRINT_U32 = r->failed;
    IO_PRINT_U32 = r->instret;
    IO_PRINT_U32 = r->a0;
    IO_PRINT_U32 = r->cause;
    IO_PRINT_U32 = r->word;
    IO_EXIT = r->verdict;
    for (;;) {}
}

void board_fault(uint32_t step, uint32_t cause) {
    IO_PRINT_U32 = 0x4641554cu;   // "FAUL"
    IO_PRINT_U32 = step;
    IO_PRINT_U32 = cause;
    IO_EXIT = 100;
    for (;;) {}
}
