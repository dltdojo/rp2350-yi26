// SPDX-License-Identifier: Apache-2.0
//
// exp228 — the same shell on the Hazard3 RTL: the testbench's print port
// instead of USB and an LED, and one round of the cases instead of forever.
//
//   CASE i code want minstret sigs valid   one case run
//   DONE cases                             every case as it should be
//   FAIL check got                         a check failed
//   FAUL step cause                        the shell itself trapped

#include "board.h"

#define IO_PRINT_U32 (*(volatile uint32_t *)0xc0000004u)
#define IO_EXIT      (*(volatile uint32_t *)0xc0000008u)

void board_init(void) {}

void board_case(uint32_t round, uint32_t i, const char *name, uint32_t code, uint32_t want, uint32_t instret,
                uint32_t sigs, uint32_t valid) {
    (void)round;
    (void)name;
    IO_PRINT_U32 = 0x43415345u;   // "CASE"
    IO_PRINT_U32 = i;
    IO_PRINT_U32 = code;
    IO_PRINT_U32 = want;
    IO_PRINT_U32 = instret;
    IO_PRINT_U32 = sigs;
    IO_PRINT_U32 = valid;
}

void board_round(uint32_t round, uint32_t cases) {
    (void)round;
    IO_PRINT_U32 = 0x444f4e45u;   // "DONE"
    IO_PRINT_U32 = cases;
    IO_EXIT = 0;
    for (;;) {}
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
