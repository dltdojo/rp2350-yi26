// SPDX-License-Identifier: Apache-2.0
//
// tools/hazard3/shell — a shell's two dead ends on the RTL, printed to the
// testbench and ended with an exit code:
//
//   FAIL check got      a check failed; the exit code is the check
//   FAUL step cause     the shell itself trapped; the exit code is 100
//
// Included by a board_sim.c after its board.h. Twelve board_sim.c files carry
// these two functions as their own; exp231 was the thirteenth to need them,
// and it and exp225, whose copy it would have been, include this instead.
#pragma once
#include <stdint.h>

#define IO_PRINT_U32 (*(volatile uint32_t *)0xc0000004u)
#define IO_EXIT      (*(volatile uint32_t *)0xc0000008u)

void board_fail(uint32_t check, uint32_t got) {
    IO_PRINT_U32 = 0x4641494cu;   // "FAIL"
    IO_PRINT_U32 = check;
    IO_PRINT_U32 = got;
    IO_EXIT = check;
    for (;;) {}
}

void board_fault(uint32_t step, uint32_t cause) {
    IO_PRINT_U32 = 0x4641554cu;   // "FAUL"
    IO_PRINT_U32 = step;
    IO_PRINT_U32 = cause;
    IO_EXIT = 100;
    for (;;) {}
}
