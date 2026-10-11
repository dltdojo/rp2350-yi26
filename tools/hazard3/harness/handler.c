// SPDX-License-Identifier: Apache-2.0
//
// tools/hazard3/harness — what a trap from the payload means.
//
// The sig.golf interface, the same two calls as lean/Rv32/Machine.lean's
// `syscall`, and everything else a fault:
//
//   ecall, t0 = 1   HALT: the payload's a0 is its result
//   ecall, t0 = 0   HASH: SHA-256 of a1 bytes at a0, 32 bytes written at a2,
//                   back to the instruction after the ecall. The arguments are
//                   checked as the model checks them — a1 a multiple of 64, a0
//                   and a2 word-aligned, both inside the region — and anything
//                   else is a fault. The hash is computed here in software; on
//                   the chip it will be the SHA-256 block (exp210).
//   ecall, t0 = 2   HASHB: HASH with no rule on a1 or on where a0 points
//                   (exp228), the same checks otherwise
//   ecall, t0 = 3   CHECKSIG: a0 becomes 1 or 0, checksig()'s answer for the
//                   32 bytes at a0 and the 64 at a1 (exp228). Without a
//                   checksig() linked in, every signature is invalid — the
//                   model's runner says the same with no RV32RUN_SIGS
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

#ifndef REGION
#define REGION      0x80010000u
#endif
#ifndef REGION_SIZE
#define REGION_SIZE 0x00010000u
#endif

#define csrr(name) ({ uint32_t v; __asm__ volatile ("csrr %0, " #name : "=r"(v)); v; })
#define csrw(name, v) __asm__ volatile ("csrw " #name ", %0" :: "r"(v))

#include "hashcall.h"
#include "sha256.h"

// The shell's signature check, if there is one; a harness alone has none.
__attribute__((weak)) int checksig(const uint8_t *pk, const uint8_t *sig) {
    (void)pk;
    (void)sig;
    return 0;
}

static void halt(uint32_t code) {
    IO_EXIT = code;
    for (;;) {}
}

void handle(uint32_t *x) {
    uint32_t cause = csrr(mcause);
    uint32_t instret = csrr(minstret);
    uint32_t cycles = csrr(mcycle);
    if (cause == 8 && x[5] == 0) {
        uint32_t src = x[10], len = x[11], dst = x[12];
        if (hash_args_ok(src, len, dst)) {
            sha256((const uint8_t *)src, len, (uint8_t *)dst);
            csrw(mepc, csrr(mepc) + 4);
            return;
        }
    }
    if (cause == 8 && x[5] == 2) {
        uint32_t src = x[10], len = x[11], dst = x[12];
        if (hashb_args_ok(src, len, dst)) {
            sha256((const uint8_t *)src, len, (uint8_t *)dst);
            csrw(mepc, csrr(mepc) + 4);
            return;
        }
    }
    if (cause == 8 && x[5] == 3) {
        if (sig_args_ok(x[10], x[11])) {
            x[10] = checksig((const uint8_t *)x[10], (const uint8_t *)x[11]) ? 1 : 0;
            csrw(mepc, csrr(mepc) + 4);
            return;
        }
    }
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
