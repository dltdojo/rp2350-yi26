// SPDX-License-Identifier: Apache-2.0
//
// exp214 — the program: invert.pio, encoded by hand from the RP2350
// datasheet's PIO instruction table; check.sh holds these words to what
// pioasm makes of invert.pio. The registers are tools/hazard3/shell/pio.h.
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
#pragma once
#include <stdint.h>

#define PROGRAM_LEN 3
static const uint16_t PROGRAM[PROGRAM_LEN] = {0x80a0, 0xa0cf, 0x8020};   // pull, mov, push
#define JMP_0 0x0000u
