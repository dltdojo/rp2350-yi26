// SPDX-License-Identifier: Apache-2.0
//
// tools/hazard3/shell — a health-test shell's verdict on the RTL, printed to
// the testbench and ended with the verdict as the exit code:
//
//   REPT verdict source failed a0 minstret cause    the shell's result
//   FAUL step cause                                 the shell itself trapped
//
// `struct result` is the includer's board.h's. exp222 wrote it, exp223 needed
// it second.
#pragma once
#include <stdint.h>

#define IO_PRINT_U32 (*(volatile uint32_t *)0xc0000004u)
#define IO_EXIT      (*(volatile uint32_t *)0xc0000008u)

void board_report(const struct result *r) {
    IO_PRINT_U32 = 0x52455054u;   // "REPT"
    IO_PRINT_U32 = r->verdict;
    IO_PRINT_U32 = r->source;
    IO_PRINT_U32 = r->failed;
    IO_PRINT_U32 = r->a0;
    IO_PRINT_U32 = r->instret;
    IO_PRINT_U32 = r->cause;
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
