// SPDX-License-Identifier: Apache-2.0
//
// exp216 — the program's words, written by proof/Program.lean from the
// instructions there through lean/Pio's proved encode. Do not edit; check.sh
// holds this file to what Lean writes and the words to what pioasm makes of
// drive.pio.
//
//   0  e081  set pindirs, 1
//   1  80a0  pull block
//   2  6020  out x, 32
//   3  0026  jmp !x, 6
//   4  e001  set pins, 1
//   5  0007  jmp 7
//   6  e000  set pins, 0
//   7  a0c1  mov isr, x
//   8  8020  push block
#pragma once
#include <stdint.h>

#define PROGRAM_LEN 9
#define WRAP_BOTTOM 1
#define WRAP_TOP 8
static const uint16_t PROGRAM[PROGRAM_LEN] = {0xe081, 0x80a0, 0x6020, 0x0026, 0xe001, 0x0007, 0xe000, 0xa0c1, 0x8020};
#define JMP_0 0x0000u
