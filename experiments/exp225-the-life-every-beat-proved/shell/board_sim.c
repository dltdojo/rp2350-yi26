// SPDX-License-Identifier: Apache-2.0
//
// exp225 — the same shell on the Hazard3 RTL: the testbench's print port
// instead of an LED, and two lives instead of forever.
//
//   LIFE round minstret gen1 gen256 centre-bits-0-31 of the life
//   FAIL check got                     a check failed
//   FAUL step cause                    the shell itself trapped

#include "board.h"

#define IO_PRINT_U32 (*(volatile uint32_t *)0xc0000004u)
#define IO_EXIT      (*(volatile uint32_t *)0xc0000008u)
#define CENTRE 16

void board_init(void) {}

void board_play(const uint32_t *life, uint32_t round, uint32_t instret) {
    uint32_t col = 0;
    for (uint32_t g = 0; g < 32; g++) col |= ((life[g] >> CENTRE) & 1) << g;
    IO_PRINT_U32 = 0x4c494645u;   // "LIFE"
    IO_PRINT_U32 = round;
    IO_PRINT_U32 = instret;
    IO_PRINT_U32 = life[0];
    IO_PRINT_U32 = life[N - 1];
    IO_PRINT_U32 = col;
    if (round == 1) {
        IO_EXIT = 0;
        for (;;) {}
    }
}

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
