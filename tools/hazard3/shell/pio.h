// SPDX-License-Identifier: Apache-2.0
//
// tools/hazard3/shell — PIO0 on the RP2350, as much of it as a shell touches,
// and the GPIO and SIO registers that hand a pin to it. Every address and
// field is rp-pac 7.0.0's for the RP235x (src/rp235x/mod.rs, pio.rs,
// pio/regs.rs, resets/regs.rs, io/vals.rs, sio.rs), written out rather than
// pulled in, as led.h does. exp214 wrote these for itself; exp216 needed them
// second; exp218 added what it reads a stopped state machine through.
#pragma once
#include <stdint.h>

#define RESETS_RESET_CLR   0x40023000u        // RESETS + 0x3000: atomic clear
#define RESETS_RESET_SET   0x40022000u        // RESETS + 0x2000: atomic set
#define RESETS_RESET_DONE  0x40020008u
#define RESET_PIO0         (1u << 11)
#define RESET_PIO1         (1u << 12)

#define PIO0               0x50200000u
#define PIO_CTRL           (PIO0 + 0x000u)
#define PIO_FSTAT          (PIO0 + 0x004u)
#define PIO_FLEVEL         (PIO0 + 0x00cu)    // TX0 bits 3:0, RX0 bits 7:4
#define PIO_TXF0           (PIO0 + 0x010u)
#define PIO_RXF0           (PIO0 + 0x020u)
#define PIO_IRQ            (PIO0 + 0x030u)    // the eight flags
#define PIO_DBG_PADOUT     (PIO0 + 0x03cu)    // the pin values PIO0 drives
#define PIO_DBG_PADOE      (PIO0 + 0x040u)    // and their output enables
#define PIO_INSTR_MEM(n)   (PIO0 + 0x048u + 4u * (n))
#define PIO_SM0_EXECCTRL   (PIO0 + 0x0c8u + 0x04u)
#define PIO_SM0_SHIFTCTRL  (PIO0 + 0x0c8u + 0x08u)
#define PIO_SM0_ADDR       (PIO0 + 0x0c8u + 0x0cu)
#define PIO_SM0_INSTR      (PIO0 + 0x0c8u + 0x10u)

#define CTRL_SM0_ENABLE    (1u << 0)          // SM_ENABLE, bits 3:0
#define CTRL_SM0_RESTART   (1u << 4)          // SM_RESTART, bits 7:4
#define CTRL_SM0_CLKDIV_RESTART (1u << 8)     // CLKDIV_RESTART, bits 11:8
#define FSTAT_SM0_RXEMPTY  (1u << 8)          // RXEMPTY, bits 11:8
#define FSTAT_SM0_TXFULL   (1u << 16)         // TXFULL, bits 19:16
#define FSTAT_SM0_TXEMPTY  (1u << 24)         // TXEMPTY, bits 27:24
#define EXECCTRL_WRAP(bottom, top) (((uint32_t)(top) << 12) | ((uint32_t)(bottom) << 7))
#define PIO_SM0_PINCTRL    (PIO0 + 0x0c8u + 0x14u)
#define PINCTRL_SET(base, count) (((uint32_t)(count) << 26) | ((uint32_t)(base) << 5))   // SET_COUNT 28:26, SET_BASE 9:5

#define GPIO_CTRL(n)       (0x40028000u + 8u * (n) + 4u)   // IO_BANK0 GPIOn_CTRL
#define GPIO_PAD(n)        (0x40038000u + 4u + 4u * (n))   // PADS_BANK0 GPIOn
#define PADS_SCHMITT       (1u << 1)
#define PADS_PDE           (1u << 2)                       // pull down
#define PADS_PUE           (1u << 3)                       // pull up
#define PADS_DRIVE_4MA     (1u << 4)                       // DRIVE, bits 5:4
#define PADS_IE            (1u << 6)                       // input enable
#define PADS_OD            (1u << 7)                       // output disable
#define FUNCSEL_PIO0       6u                              // io/vals.rs: PIO0_n = 0x06
#ifndef FUNCSEL_SIO
#define FUNCSEL_SIO        5u                              // SIOB_PROC_n = 0x05, as led.h has it
#endif
#define SIO_GPIO_IN        0xd0000004u                     // SIO + 0x004: GPIO0..31 as read at the pad
