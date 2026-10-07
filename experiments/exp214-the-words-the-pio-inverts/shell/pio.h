// SPDX-License-Identifier: Apache-2.0
//
// exp214 — PIO0 on the RP2350, as much of it as the shell touches, and the
// program. Every address and field is rp-pac 7.0.0's for the RP235x
// (src/rp235x/mod.rs, pio.rs, pio/regs.rs, resets/regs.rs), written out
// rather than pulled in, as tools/hazard3/shell/led.h does.
#pragma once
#include <stdint.h>

#define RESETS_RESET_CLR   0x40023000u        // RESETS + 0x3000: atomic clear
#define RESETS_RESET_DONE  0x40020008u
#define RESET_PIO0         (1u << 11)

#define PIO0               0x50200000u
#define PIO_CTRL           (PIO0 + 0x000u)
#define PIO_FSTAT          (PIO0 + 0x004u)
#define PIO_TXF0           (PIO0 + 0x010u)
#define PIO_RXF0           (PIO0 + 0x020u)
#define PIO_INSTR_MEM(n)   (PIO0 + 0x048u + 4u * (n))
#define PIO_SM0_EXECCTRL   (PIO0 + 0x0c8u + 0x04u)
#define PIO_SM0_INSTR      (PIO0 + 0x0c8u + 0x10u)

#define CTRL_SM0_ENABLE    (1u << 0)          // SM_ENABLE, bits 3:0
#define CTRL_SM0_RESTART   (1u << 4)          // SM_RESTART, bits 7:4
#define CTRL_SM0_CLKDIV_RESTART (1u << 8)     // CLKDIV_RESTART, bits 11:8
#define FSTAT_SM0_RXEMPTY  (1u << 8)          // RXEMPTY, bits 11:8
#define FSTAT_SM0_TXFULL   (1u << 16)         // TXFULL, bits 19:16
#define FSTAT_SM0_TXEMPTY  (1u << 24)         // TXEMPTY, bits 27:24
#define EXECCTRL_WRAP(bottom, top) (((uint32_t)(top) << 12) | ((uint32_t)(bottom) << 7))

// invert.pio, encoded by hand from the RP2350 datasheet's PIO instruction
// table; check.sh holds these words to what pioasm makes of invert.pio.
//
//                   op  delay pull IfE/IfF Block
//   pull block      100 00000  1      0     1    00000   0x80a0
//   push block      100 00000  0      0     1    00000   0x8020
//                   op  delay  dest     op   src
//   mov isr, ~osr   101 00000  110 ISR  01 ~ 111 OSR     0xa0cf
//
// and the one instruction the shell executes directly, to start at 0:
//
//   jmp 0           000 00000 000 00000             0x0000
#define PROGRAM_LEN 3
static const uint16_t PROGRAM[PROGRAM_LEN] = {0x80a0, 0xa0cf, 0x8020};   // pull, mov, push
#define JMP_0 0x0000u
