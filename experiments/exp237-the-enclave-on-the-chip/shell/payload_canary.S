// SPDX-License-Identifier: Apache-2.0
//
// exp237 — a payload that leaves a secret in every register it can, then halts.
// The shell reads the caller-saved registers back after the monitor returns and
// wants every one of them zero (a0 is the exit code, 0x5a).
.section .text
.globl _start
_start:
    li    x1, 0xa5a5a5a5
    li    x2, 0xa5a5a5a5
    li    x3, 0xa5a5a5a5
    li    x4, 0xa5a5a5a5
    li    x6, 0xa5a5a5a5
    li    x7, 0xa5a5a5a5
    li    x8, 0xa5a5a5a5
    li    x9, 0xa5a5a5a5
    li    x11, 0xa5a5a5a5
    li    x12, 0xa5a5a5a5
    li    x13, 0xa5a5a5a5
    li    x14, 0xa5a5a5a5
    li    x15, 0xa5a5a5a5
    li    x16, 0xa5a5a5a5
    li    x17, 0xa5a5a5a5
    li    x18, 0xa5a5a5a5
    li    x19, 0xa5a5a5a5
    li    x20, 0xa5a5a5a5
    li    x21, 0xa5a5a5a5
    li    x22, 0xa5a5a5a5
    li    x23, 0xa5a5a5a5
    li    x24, 0xa5a5a5a5
    li    x25, 0xa5a5a5a5
    li    x26, 0xa5a5a5a5
    li    x27, 0xa5a5a5a5
    li    x28, 0xa5a5a5a5
    li    x29, 0xa5a5a5a5
    li    x30, 0xa5a5a5a5
    li    x31, 0xa5a5a5a5
    li    a0, 0x5a
    li    t0, 1
    ecall
