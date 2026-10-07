// SPDX-License-Identifier: Apache-2.0
//
// exp221 — the same shell on the Hazard3 RTL. The kernel runs for real there,
// as in exp209 to exp220; the RTL has no PIO, so each block's reads are
// answered by a stand-in, chosen with -DDEVICE=:
//
//   0  two blocks that work: PIO0 complements, PIO1 reverses
//   1  PIO1 never comes out of reset
//   2  PIO1 hands each word back as it was
//   3  PIO0 answers wrongly the second time it sees a word's path — each
//      block right on its own, the orders disagreeing
//   4  PIO0 never answers
//   5  PIO1's RX still holds a word at the end
//
// Not a model of PIO: it shows that the shell takes each verdict where it
// should.
//
//   REPT verdict failed minstret a0 cause word block    the shell's result
//   FAUL step cause                                     the shell itself trapped

#include "board.h"
#include "pio.h"

#ifndef DEVICE
#define DEVICE 0
#endif

#define IO_PRINT_U32 (*(volatile uint32_t *)0xc0000004u)
#define IO_EXIT      (*(volatile uint32_t *)0xc0000008u)

static uint32_t last[2], pending[2], sent[2];

static uint32_t reverse(uint32_t w) {
    uint32_t r = 0;
    for (uint32_t i = 0; i < 32; i++) r |= ((w >> i) & 1u) << (31 - i);
    return r;
}

static int block(uint32_t addr, uint32_t base) { return addr >= base && addr < base + 0x100000u; }

uint32_t rd(uint32_t addr) {
    if (addr == RESETS_RESET_DONE) return DEVICE == 1 ? RESET_PIO0 : RESET_PIO0 | RESET_PIO1;
    int b = block(addr, PIO1);
    if (!b && !block(addr, PIO0)) return 0;
    uint32_t base = b ? PIO1 : PIO0;
    if (addr == PIOB_FSTAT(base)) {
        uint32_t f = FSTAT_SM0_TXEMPTY;
        if (!pending[b] || (DEVICE == 4 && !b)) f |= FSTAT_SM0_RXEMPTY;
        if (DEVICE == 5 && b && sent[1] == 32) f &= ~FSTAT_SM0_RXEMPTY;   // after all 16 words, both ways
        return f;
    }
    if (addr == PIOB_RXF0(base)) {
        pending[b] = 0;
        if (b) return DEVICE == 2 ? last[1] : reverse(last[1]);
        if (DEVICE == 3 && sent[0] % 2 == 0) return ~last[0] ^ 1u;
        return ~last[0];
    }
    return 0;
}

void wr(uint32_t addr, uint32_t v) {
    for (int b = 0; b < 2; b++)
        if (addr == PIOB_TXF0(b ? PIO1 : PIO0)) { last[b] = v; pending[b] = 1; sent[b]++; }
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
    IO_PRINT_U32 = r->block;
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
