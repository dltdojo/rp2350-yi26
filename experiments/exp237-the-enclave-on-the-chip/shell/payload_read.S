// SPDX-License-Identifier: Apache-2.0
//
// exp237 — a payload that reads the monitor's own code. PMP must stop it: the
// monitor reports FAULT with mcause 5 (load access fault).
#include "mem_layout.h"
.section .text
.globl _start
_start:
    li    t0, MONITOR_BASE + 0x40
    lw    t1, 0(t0)
    li    t0, 1
    ecall
