// SPDX-License-Identifier: Apache-2.0
//
// exp218 — the same shell on the Hazard3 RTL, which has no PIO and no GPIO.
// Every write is printed instead of made, for check.sh to hold to the
// writes expected.py says the protocol makes; every read is answered by a
// stand-in chosen with -DDEVICE=:
//
//   0  a PIO that holds, at each stop, what cases.h says the model holds
//   1  one that never comes out of reset
//   2  one that pushes on case 2's `push iffull` (rp2040js's reading)
//   3  one whose pins stop at 31 in case 13 (both emulators' reading)
//   4  one that never hands a word out in case 18's readout
//   5  one whose X is wrong in every case
//
// The stand-in reads its answers out of cases.h, so device 0 agreeing says
// nothing about PIO: it shows that the shell takes each stop, reads each
// register and each word, and compares each with the model's, and the
// others that it says which cases differ.
//
//   WRIT addr value              a register write
//   REPT failed fields-of-first  the shell's verdict
//   RSET case                    PIO0 never came out of reset
//   FAUL step cause              the shell itself trapped

#include "board.h"
#include "cases.h"
#include "pio.h"

#ifndef DEVICE
#define DEVICE 0
#endif

#define IO_PRINT_U32 (*(volatile uint32_t *)0xc0000004u)
#define IO_EXIT      (*(volatile uint32_t *)0xc0000008u)

static int32_t current = -1;          // the case, counted by its reset
static uint32_t stops;                // how many times it has been disabled
static uint32_t queue[8], head, tail; // RX, as the stand-in fills it
static uint32_t src;                  // what `mov isr, …` last named: 0 ISR, else the instruction

static const struct pio_want *want(void) { return &CASES[current].want; }

static void put(uint32_t v) { queue[tail++ % 8] = v; }

static void fill(uint32_t n, const uint32_t *ws) {
    for (uint32_t i = 0; i < n; i++) put(ws[i]);
}

static uint32_t reg_value(void) {
    const struct pio_want *w = want();
    switch (src) {
    case I_MOV_ISR_X: return DEVICE == 5 ? w->x ^ 1u : w->x;
    case I_MOV_ISR_Y: return w->y;
    case I_MOV_ISR_OSR: return w->osr;
    default: return w->isr;
    }
}

uint32_t rd(uint32_t addr) {
    switch (addr) {
    case RESETS_RESET_DONE:
        return DEVICE == 1 ? 0 : RESET_PIO0;
    case PIO_FSTAT:
        return head == tail ? FSTAT_SM0_RXEMPTY : 0;
    case PIO_RXF0:
        return head == tail ? 0 : queue[head++ % 8];
    case PIO_SM0_ADDR:
        return want()->pc;
    case PIO_IRQ:
        return want()->irq;
    case PIO_DBG_PADOUT:
        return DEVICE == 3 && current == 12 ? want()->padout & ~3u : want()->padout;
    case PIO_DBG_PADOE:
        return want()->padoe;
    case PIO_FLEVEL:
        return want()->txlevel;
    default:
        return 0;
    }
}

void wr(uint32_t addr, uint32_t v) {
    IO_PRINT_U32 = 0x57524954u;   // "WRIT"
    IO_PRINT_U32 = addr;
    IO_PRINT_U32 = v;
    if (addr == RESETS_RESET_SET && (v & RESET_PIO0)) {
        current++;
        stops = 0;
        head = tail = 0;
    } else if (addr == PIO_CTRL && v == 0 && current >= 0) {
        stops++;
        if (stops == 1) {
            fill(want()->nrx1, want()->rx1);
            if (DEVICE == 2 && current == 1) put(0x50000000u);
        } else if (stops == 2) {
            fill(want()->nrx2, want()->rx2);
        }
    } else if (addr == PIO_SM0_INSTR && stops >= 2) {
        if (v == I_PUSH) {
            if (!(DEVICE == 4 && current == 17)) put(reg_value());
            src = 0;
        } else {
            src = v;
        }
    }
}

void board_init(void) {}

void board_report(uint32_t failed, uint32_t fields_of_first) {
    IO_PRINT_U32 = 0x52455054u;   // "REPT"
    IO_PRINT_U32 = failed;
    IO_PRINT_U32 = fields_of_first;
    IO_EXIT = failed ? 1 : 0;
    for (;;) {}
}

void board_reset_failed(uint32_t failed_case) {
    IO_PRINT_U32 = 0x52534554u;   // "RSET"
    IO_PRINT_U32 = failed_case;
    IO_EXIT = 2;
    for (;;) {}
}

void board_fault(uint32_t step, uint32_t cause) {
    IO_PRINT_U32 = 0x4641554cu;   // "FAUL"
    IO_PRINT_U32 = step;
    IO_PRINT_U32 = cause;
    IO_EXIT = 100;
    for (;;) {}
}
