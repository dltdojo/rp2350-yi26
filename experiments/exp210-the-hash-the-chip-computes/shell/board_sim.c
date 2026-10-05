// SPDX-License-Identifier: Apache-2.0
//
// exp210 — the same shell on the Hazard3 RTL: HASH in software, as the RTL
// harness's handler.c does it, and the testbench's print port instead of an
// LED. The one thing this build cannot run is sha_hw.h; host/shatest.py holds
// that against a fake.
//
//   CASE i ok failed a0 minstret mcause    each case, as it ends
//   REPT ok failed-cases                   the verdict
//   FAUL step mcause                       the shell itself trapped

#include "board.h"
#include "sha256.h"

#define IO_PRINT_U32 (*(volatile uint32_t *)0xc0000004u)
#define IO_EXIT      (*(volatile uint32_t *)0xc0000008u)

void board_init(void) {}

int board_hash(const uint8_t *src, uint32_t len, uint8_t *dst) {
    sha256(src, len, dst);
    return 1;
}

void board_case(uint32_t i, const struct outcome *o) {
    IO_PRINT_U32 = 0x43415345u;   // "CASE"
    IO_PRINT_U32 = i;
    IO_PRINT_U32 = o->ok;
    IO_PRINT_U32 = o->failed;
    IO_PRINT_U32 = o->a0;
    IO_PRINT_U32 = o->instret;
    IO_PRINT_U32 = o->cause;
}

void board_report(uint32_t ok, uint32_t failed_cases) {
    IO_PRINT_U32 = 0x52455054u;   // "REPT"
    IO_PRINT_U32 = ok;
    IO_PRINT_U32 = failed_cases;
    IO_EXIT = !ok;
    for (;;) {}
}

void board_fault(uint32_t step, uint32_t cause) {
    IO_PRINT_U32 = 0x4641554cu;   // "FAUL"
    IO_PRINT_U32 = step;
    IO_PRINT_U32 = cause;
    IO_EXIT = 100;
    for (;;) {}
}
