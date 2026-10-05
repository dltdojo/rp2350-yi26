// SPDX-License-Identifier: Apache-2.0
//
// exp209 — the same shell on the Hazard3 RTL: the testbench's print port
// instead of an LED, and its exit port instead of forever.
//
//   REPT ok failed minstret pmpcfg0 pmpaddr0^want a0 cause    the shell's result
//   FAUL step cause                                  the shell itself trapped

#include "board.h"

#define IO_PRINT_U32 (*(volatile uint32_t *)0xc0000004u)
#define IO_EXIT      (*(volatile uint32_t *)0xc0000008u)

void board_init(void) {}

void board_report(const struct result *r) {
    IO_PRINT_U32 = 0x52455054u;   // "REPT"
    IO_PRINT_U32 = r->ok;
    IO_PRINT_U32 = r->failed;
    IO_PRINT_U32 = r->instret;
    IO_PRINT_U32 = r->pmpcfg;
    IO_PRINT_U32 = r->pmpaddr_xor;
    IO_PRINT_U32 = r->a0;
    IO_PRINT_U32 = r->cause;
    IO_EXIT = !r->ok;
    for (;;) {}
}

void board_fault(uint32_t step, uint32_t cause) {
    IO_PRINT_U32 = 0x4641554cu;   // "FAUL"
    IO_PRINT_U32 = step;
    IO_PRINT_U32 = cause;
    IO_EXIT = 100;
    for (;;) {}
}
