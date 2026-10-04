// SPDX-License-Identifier: Apache-2.0
//
// exp202 — the environment riscv-tests runs in, rewritten for the verified
// kernel's interface instead of a machine with a host.
//
// The suite's own environments ("p", "v") start in Machine mode, set up trap
// vectors with CSR writes, and report through a `tohost` word a simulator
// watches. None of that exists in the model: a test here starts at its first
// instruction in User mode, with every register zero but sp, and the only way
// out is `ecall` with t0 = 1 and the result in a0. So:
//
//   RVTEST_PASS   HALT with a0 = 0
//   RVTEST_FAIL   HALT with a0 = (TESTNUM << 1) | 1 — never zero, and the
//                 failing case's number is in it
//
// Everything a test *checks* is the suite's, untouched: the macros in
// isa/macros/scalar/test_macros.h and the test files themselves.

#ifndef YI26_RISCV_TEST_H
#define YI26_RISCV_TEST_H

#define RVTEST_RV32U .macro init; .endm
#define RVTEST_RV64U RVTEST_RV32U

#define TESTNUM gp

#define RVTEST_CODE_BEGIN \
        .section .text.init; \
        .globl _start; \
_start:

#define RVTEST_CODE_END

#define RVTEST_PASS \
        li t0, 1; \
        li a0, 0; \
        ecall

#define RVTEST_FAIL \
        slli a0, TESTNUM, 1; \
        ori a0, a0, 1; \
        li t0, 1; \
        ecall

#define EXTRA_DATA
#define RVTEST_DATA_BEGIN .balign 4;
#define RVTEST_DATA_END

#endif
