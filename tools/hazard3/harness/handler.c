// SPDX-License-Identifier: Apache-2.0
//
// tools/hazard3/harness — what a trap from the payload means.
//
// The sig.golf interface, the same two calls as lean/Rv32/Machine.lean's
// `syscall`, and everything else a fault:
//
//   ecall, t0 = 1   HALT: the payload's a0 is its result
//   ecall, t0 = 0   HASH: not in this harness yet — the first experiment that
//                   needs it (exp204) adds it, and until then it is a fault,
//                   so that nothing can pass by calling it
//   anything else   a fault, reported with mcause, mepc and mtval
//
// Results go to the testbench's print port as one tagged line of hex words,
// which tools/hazard3/sim.sh reads:
//
//   HALT  code instret cycles
//   FAULT mcause mepc mtval instret

#include <stdint.h>

#define IO_PRINT_U32 (*(volatile uint32_t *)0xc0000004u)
#define IO_EXIT      (*(volatile uint32_t *)0xc0000008u)

#define TAG_HALT  0x48414c54u   // "HALT"
#define TAG_FAULT 0x4641554cu   // "FAUL"

#define csrr(name) ({ uint32_t v; __asm__ volatile ("csrr %0, " #name : "=r"(v)); v; })

static void halt(uint32_t code) {
    IO_EXIT = code;
    for (;;) {}
}

void handle(uint32_t *x) {
    uint32_t cause = csrr(mcause);
    uint32_t instret = csrr(minstret);
    uint32_t cycles = csrr(mcycle);
    if (cause == 8 && x[5] == 1) {
        IO_PRINT_U32 = TAG_HALT;
        IO_PRINT_U32 = x[10];
        IO_PRINT_U32 = instret;
        IO_PRINT_U32 = cycles;
        halt(x[10] == 0 ? 0 : 1);
    }
    IO_PRINT_U32 = TAG_FAULT;
    IO_PRINT_U32 = cause;
    IO_PRINT_U32 = csrr(mepc);
    IO_PRINT_U32 = csrr(mtval);
    IO_PRINT_U32 = instret;
    halt(2);
}
