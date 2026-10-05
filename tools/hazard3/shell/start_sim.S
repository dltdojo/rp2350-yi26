// SPDX-License-Identifier: Apache-2.0
//
// tools/hazard3/shell — where the shell starts on the Hazard3 RTL, at the testbench's
// reset vector: the same shell, with the print port for an LED.

.section .text.entry, "ax"
.org 0
    j     trap
.org 0x40
.globl _start
_start:
    li    sp, MSTACK
    la    t0, trap
    csrw  mtvec, t0
    la    t0, __bss_start
    la    t1, __bss_end
1:  bgeu  t0, t1, 2f
    sw    zero, 0(t0)
    addi  t0, t0, 4
    j     1b
2:  call  shell_main
3:  j     3b
