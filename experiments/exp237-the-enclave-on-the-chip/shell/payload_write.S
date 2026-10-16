// SPDX-License-Identifier: Apache-2.0
//
// exp237 — a payload that overwrites the monitor's own code. PMP must stop it:
// FAULT with mcause 7 (store access fault), and the monitor's bytes unchanged.
#include "mem_layout.h"
.section .text
.globl _start
_start:
    li    t0, MONITOR_BASE + 0x40
    li    t1, -1
    sw    t1, 0(t0)
    li    t0, 1
    ecall
