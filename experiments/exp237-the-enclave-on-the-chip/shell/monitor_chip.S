// SPDX-License-Identifier: Apache-2.0
//
// exp237 — Verified RISC-V M-Mode Micro-Monitor for RP2350 Silicon (monitor_chip.S)
//
// Loaded into SRAM Domain 0 (0x20000000).
// Offsets:
//   0x00: Boot reset jump
//   0x20: launch_enclave (C-callable entry point)
//   0x40: _reset (Monitor initialization, PMP setup, mret to U-mode)
//   0x80+: trap_handler (Trap interception, mailbox report, secret zeroization, ret to C)

.section .text.monitor, "ax"
.globl _start
.globl launch_enclave
.globl _reset
.globl trap_handler

.org 0x00
_start:
    j _reset

.org 0x20
launch_enclave:
    // Called from C launcher:
    // Saves Host C caller's sp and ra into 0x20000420 / 0x20000424, then enters monitor
    li    t0, 0x20000420
    sw    sp, 0(t0)
    sw    ra, 4(t0)
    j     _reset

.org 0x40
_reset:
    // Setup trap handler vector (direct mode at trap_handler)
    la    t0, trap_handler
    csrw  mtvec, t0

    // Setup M-mode stack in mscratch (0x20008000)
    li    t0, 0x20008000
    csrw  mscratch, t0

    // Freeze hardware counters during boot
    csrwi mcountinhibit, 5

    // Configure PMP entry 0: 64 KiB NAPOT at 0x20010000 (0x08005fff)
    li    t0, 0x08005fff
    csrw  pmpaddr0, t0
    // PMP cfg 0: NAPOT (0b11), R=1, W=1, X=1 (0x1f), other entries OFF
    li    t0, 0x1f
    csrw  pmpcfg0, t0

    // Setup payload entry point in mepc (0x20010000)
    li    t0, 0x20010000
    csrw  mepc, t0

    // Clear mstatus.MPP to User mode (0b00)
    li    t0, 0x1800
    csrc  mstatus, t0

    // Zero hardware performance counters
    csrw  minstret, zero
    csrw  minstreth, zero
    csrw  mcycle, zero
    csrw  mcycleh, zero

    // Initialize U-mode stack pointer (top of region: 0x20020000)
    li    sp, 0x20020000

    // Zero all general purpose registers before launching payload
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

    // Unfreeze hardware counters immediately before mret
    csrwi mcountinhibit, 0
    mret

.balign 4
trap_handler:
    // Freeze counters immediately
    csrwi mcountinhibit, 5

    // Switch to M-mode stack
    csrrw sp, mscratch, sp

    // Save scratch registers t0, t1 on M-mode stack
    sw    t0, 0(sp)
    sw    t1, 4(sp)

    // Read mcause
    csrr  t0, mcause

    // Check if mcause == 8 (CAUSE_ECALL_UMODE)
    li    t1, 8
    beq   t0, t1, handle_ecall

handle_fault:
    // Report FAULT to mailbox at 0x20000400:
    // [0x00]: TAG_FAULT (0x4641554c)
    // [0x04]: exit_code = 1
    // [0x08]: minstret
    // [0x0c]: mcycle
    // [0x10]: mcause
    // [0x14]: mepc
    // [0x18]: mtval
    li    t1, 0x20000400
    li    t0, 0x4641554c
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
    // Check syscall number in t0 (saved on stack at 0(sp))
    lw    t0, 0(sp)
    li    t1, 1
    bne   t0, t1, handle_fault

handle_halt:
    // Normal HALT:
    // Write report to 0x20000400:
    // [0x00]: TAG_HALT (0x48414c54)
    // [0x04]: exit_code = a0
    // [0x08]: minstret
    // [0x0c]: mcycle
    // [0x10]: mcause = 0
    // [0x14]: mepc = 0
    // [0x18]: mtval = 0
    li    t1, 0x20000400
    li    t0, 0x48414c54
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
    // Secret zeroization: scrub all general purpose registers except a0 (x10)
    li    x1, 0
    li    x2, 0
    li    x3, 0
    li    x4, 0
    li    x5, 0
    li    x6, 0
    li    x7, 0
    li    x8, 0
    li    x9, 0
    // Preserve a0 (x10)
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

    // Restore Host C launcher's stack and return address from 0x20000420
    li    t1, 0x20000420
    lw    sp, 0(t1)
    lw    ra, 4(t1)
    li    t1, 0
    ret
