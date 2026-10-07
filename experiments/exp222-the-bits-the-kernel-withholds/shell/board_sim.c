// SPDX-License-Identifier: Apache-2.0
//
// exp222 — the same shell on the Hazard3 RTL. The kernel runs for real there;
// the RTL has no TRNG, so a stand-in gives its words, chosen with -DDEVICE=:
//
//   0  words from a fixed LCG, whose 1024 bits pass both tests
//   1  words that are all ones: the TRNG's own samples withheld
//   2  no words at all: the TRNG gave nothing
//
// Not a model of the TRNG: it shows that the shell takes each verdict where
// it should, with the kernel's own halting deciding the first two.
//
//   REPT verdict source failed a0 minstret cause    the shell's result
//   FAUL step cause                                 the shell itself trapped

#include "board.h"

#ifndef DEVICE
#define DEVICE 0
#endif

#define IO_PRINT_U32 (*(volatile uint32_t *)0xc0000004u)
#define IO_EXIT      (*(volatile uint32_t *)0xc0000008u)

int board_trng(uint32_t *words, uint32_t n) {
    if (DEVICE == 2) return 0;
    uint32_t x = 222;
    for (uint32_t i = 0; i < n; i++) {
        x = x * 1664525u + 1013904223u;
        words[i] = DEVICE == 1 ? 0xffffffffu : x;
    }
    return 1;
}

void board_init(void) {}

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
