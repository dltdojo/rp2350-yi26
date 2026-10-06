// SPDX-License-Identifier: Apache-2.0
//
// exp212 — the same shell on the Hazard3 RTL: HASH in software, as the RTL
// harness's handler.c does it, and the testbench's print port instead of an
// LED.
//
//   RUN_ i failed mcycle minstret    each run, as it ends
//   REPT verdict                     2 slow, 1 double, 0 fast
//   FAUL step mcause                 the shell itself trapped

#include "board.h"
#include "sha256.h"

#define IO_PRINT_U32 (*(volatile uint32_t *)0xc0000004u)
#define IO_EXIT      (*(volatile uint32_t *)0xc0000008u)

void board_init(void) {}

int board_hash(const uint8_t *src, uint32_t len, uint8_t *dst) {
    sha256(src, len, dst);
    return 1;
}

void board_run(uint32_t i, const struct result *r, uint32_t instret) {
    IO_PRINT_U32 = 0x52554e5fu;   // "RUN_"
    IO_PRINT_U32 = i;
    IO_PRINT_U32 = r->failed;
    IO_PRINT_U32 = r->cycles;
    IO_PRINT_U32 = instret;
}

void board_report(uint32_t v) {
    IO_PRINT_U32 = 0x52455054u;   // "REPT"
    IO_PRINT_U32 = v;
    IO_EXIT = v != SLOW;
    for (;;) {}
}

void board_fault(uint32_t step, uint32_t cause) {
    IO_PRINT_U32 = 0x4641554cu;   // "FAUL"
    IO_PRINT_U32 = step;
    IO_PRINT_U32 = cause;
    IO_EXIT = 100;
    for (;;) {}
}
