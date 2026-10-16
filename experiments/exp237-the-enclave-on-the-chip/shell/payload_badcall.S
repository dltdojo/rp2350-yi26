// SPDX-License-Identifier: Apache-2.0
//
// exp237 — a payload that makes a system call the monitor does not serve (7, not
// HALT = 1). The monitor reports FAULT with mcause 8, a0 = 1: an ecall it does not
// know is not a halt.
.section .text
.globl _start
_start:
    li    t0, 7
    li    a0, 0
    ecall
