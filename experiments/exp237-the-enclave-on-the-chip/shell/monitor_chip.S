// SPDX-License-Identifier: Apache-2.0
//
// exp237 — M-mode micro-monitor for RP2350 silicon (monitor_chip.S).
//
// Derived from exp236's monitor.S, NOT the same program: exp236's Lean proofs
// cover exp236/monitor.bin and nothing here. What differs, and is therefore
// unproved: it runs at MONITOR_BASE, reports into a mailbox in SRAM instead of
// a print port, and returns to its C caller instead of parking.
//
// Loaded at MONITOR_BASE. Entry points:
//   +0x00  _start          j _reset
//   +0x20  launch_enclave  C-callable: uint32_t launch_enclave(void)
//
// launch_enclave saves the caller's sp, ra, gp, tp, s0..s11 and mcountinhibit
// at MONITOR_HOST_CTX, runs the payload in U-mode behind PMP entry 0, and on
// the payload's trap puts everything the C ABI says is the callee's back,
// zeroes every other register but a0, and returns a0 (0 = clean HALT, the
// payload's exit code; 1 = fault).

#include "mem_layout.h"

.section .text.monitor, "ax"
.globl _start
.globl launch_enclave
.globl _reset
.globl trap_handler

.org 0x00
_start:
    j     _reset

.org 0x20
launch_enclave:
    li    t0, MONITOR_HOST_CTX
    sw    sp,  0(t0)
    sw    ra,  4(t0)
    sw    gp,  8(t0)
    sw    tp, 12(t0)
    sw    s0, 16(t0)
    sw    s1, 20(t0)
    sw    s2, 24(t0)
    sw    s3, 28(t0)
    sw    s4, 32(t0)
    sw    s5, 36(t0)
    sw    s6, 40(t0)
    sw    s7, 44(t0)
    sw    s8, 48(t0)
    sw    s9, 52(t0)
    sw    s10, 56(t0)
    sw    s11, 60(t0)
    csrr  t1, mcountinhibit
    sw    t1, 64(t0)

_reset:
    la    t0, trap_handler
    csrw  mtvec, t0

    li    t0, MONITOR_STACK
    csrw  mscratch, t0

    // Freeze the counters while we set up.
    csrwi mcountinhibit, 5

    // PMP entry 0: 64 KiB NAPOT over the payload, RWX, unlocked; the rest OFF.
    li    t0, DOMAIN_PMPADDR0
    csrw  pmpaddr0, t0
    li    t0, DOMAIN_PMPCFG0
    csrw  pmpcfg0, t0

    // Read both back: what the silicon kept, for the shell to check.
    csrr  t1, pmpcfg0
    csrr  t2, pmpaddr0
    li    t0, MONITOR_BOOT
    sw    t1, 0(t0)
    sw    t2, 4(t0)

    li    t0, PAYLOAD_BASE
    csrw  mepc, t0

    // mstatus.MPP = User
    li    t0, 0x1800
    csrc  mstatus, t0

    csrw  minstret, zero
    csrw  minstreth, zero
    csrw  mcycle, zero
    csrw  mcycleh, zero

    li    sp, PAYLOAD_STACK

    li    x1, 0
    li    x3, 0
    li    x4, 0
    li    x5, 0
    li    x6, 0
    li    x7, 0
    li    x8, 0
    li    x9, 0
    li    x10, 0
    li    x11, 0
    li    x12, 0
    li    x13, 0
    li    x14, 0
    li    x15, 0
    li    x16, 0
    li    x17, 0
    li    x18, 0
    li    x19, 0
    li    x20, 0
    li    x21, 0
    li    x22, 0
    li    x23, 0
    li    x24, 0
    li    x25, 0
    li    x26, 0
    li    x27, 0
    li    x28, 0
    li    x29, 0
    li    x30, 0
    li    x31, 0

    csrwi mcountinhibit, 0
    mret

.balign 4
trap_handler:
    // Freeze the counters first: the monitor's own instructions are not the payload's.
    csrwi mcountinhibit, 5

    // sp <-> mscratch: sp is the M-mode stack, mscratch the payload's sp.
    csrrw sp, mscratch, sp
    sw    t0, 0(sp)
    sw    t1, 4(sp)

    csrr  t0, mcause
    li    t1, 8                     // environment call from U-mode
    beq   t0, t1, handle_ecall

handle_fault:
    li    t1, MONITOR_REPORT
    li    t0, TAG_FAULT
    sw    t0, 0(t1)
    li    t0, 1
    sw    t0, 4(t1)
    csrr  t0, minstret
    sw    t0, 8(t1)
    csrr  t0, mcycle
    sw    t0, 12(t1)
    csrr  t0, mcause
    sw    t0, 16(t1)
    csrr  t0, mepc
    sw    t0, 20(t1)
    csrr  t0, mtval
    sw    t0, 24(t1)
    li    a0, 1
    j     scrub_exit

handle_ecall:
    lw    t0, 0(sp)                 // the payload's t0: the syscall number
    li    t1, 1                     // SYS_HALT
    bne   t0, t1, handle_fault

handle_halt:
    li    t1, MONITOR_REPORT
    li    t0, TAG_HALT
    sw    t0, 0(t1)
    sw    a0, 4(t1)
    csrr  t0, minstret
    sw    t0, 8(t1)
    csrr  t0, mcycle
    sw    t0, 12(t1)
    sw    zero, 16(t1)
    sw    zero, 20(t1)
    sw    zero, 24(t1)

scrub_exit:
    // Nothing of the payload's stays in the monitor: the two saved words,
    // mscratch (the payload's sp), and the PMP entry.
    sw    zero, 0(sp)
    sw    zero, 4(sp)
    csrw  mscratch, zero
    csrw  pmpcfg0, zero
    csrw  pmpaddr0, zero

    // The caller's registers back: sp, ra, gp, tp, s0..s11, and its counters' state.
    li    t1, MONITOR_HOST_CTX
    lw    t0, 64(t1)
    csrw  mcountinhibit, t0
    lw    sp,  0(t1)
    lw    ra,  4(t1)
    lw    gp,  8(t1)
    lw    tp, 12(t1)
    lw    s0, 16(t1)
    lw    s1, 20(t1)
    lw    s2, 24(t1)
    lw    s3, 28(t1)
    lw    s4, 32(t1)
    lw    s5, 36(t1)
    lw    s6, 40(t1)
    lw    s7, 44(t1)
    lw    s8, 48(t1)
    lw    s9, 52(t1)
    lw    s10, 56(t1)
    lw    s11, 60(t1)

    // Every caller-saved register but a0 (the return value): zero.
    li    x5, 0
    li    x7, 0
    li    x11, 0
    li    x12, 0
    li    x13, 0
    li    x14, 0
    li    x15, 0
    li    x16, 0
    li    x17, 0
    li    x28, 0
    li    x29, 0
    li    x30, 0
    li    x31, 0
    li    x6, 0
    ret
