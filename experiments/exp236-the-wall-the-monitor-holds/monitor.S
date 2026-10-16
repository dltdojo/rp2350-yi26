// SPDX-License-Identifier: Apache-2.0
//
// exp236 — Verified RISC-V M-Mode Micro-Monitor (monitor.S)
//
// A compact, verified M-mode micro-monitor in pure RV32I + Zicsr:
//   1. Configures hardware PMP entry 0 in NAPOT mode covering 64 KiB
//      payload region [0x80010000, 0x80020000) with RWX permissions,
//      leaving all other physical memory in default-deny.
//   2. Clears all general purpose registers and initializes U-mode stack.
//   3. Switches to User mode via mret with precise counter unfreezing.
//   4. On ecall (t0 = 1): reports HALT with exit code and cycle counts,
//      scrubs all registers x1..x9 and x11..x31 to 0, and halts.
//   5. On fault (PMP violation, illegal CSR, etc.): catches trap,
//      reports FAULT with mcause, mepc, mtval, and halts safely.

.section .text.entry, "ax"
.globl _start
.globl _reset
.globl trap_handler

.org 0
_start:
    j _reset

.org 0x40
_reset:
    // Setup trap handler vector
    la    t0, trap_handler
    csrw  mtvec, t0

    // Setup M-mode stack in mscratch
    li    t0, 0x80008000
    csrw  mscratch, t0

    // Freeze hardware counters during boot
    csrwi mcountinhibit, 5

    // Configure PMP entry 0: 64 KiB NAPOT at 0x80010000 (0x20005fff)
    li    t0, 0x20005fff
    csrw  pmpaddr0, t0
    // PMP cfg 0: NAPOT (0b11), R=1, W=1, X=1 (0x1f), other entries OFF
    li    t0, 0x1f
    csrw  pmpcfg0, t0

    // Setup payload entry point in mepc (0x80010000)
    li    t0, 0x80010000
    csrw  mepc, t0

    // Clear mstatus.MPP to User mode (0b00)
    li    t0, 0x1800
    csrc  mstatus, t0

    // Zero hardware performance counters
    csrw  minstret, zero
    csrw  minstreth, zero
    csrw  mcycle, zero
    csrw  mcycleh, zero

    // Initialize U-mode stack pointer (top of region: 0x80020000)
    li    sp, 0x80020000

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

    // Enter U-mode
    mret

.balign 4
trap_handler:
    // Immediately freeze counters so monitor instructions do not leak into count
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
    // Report FAULT to testbench print port (0xc0000004):
    // TAG_FAULT (0x4641554c "FAUL"), mcause, mepc, mtval, minstret
    li    t1, 0xc0000004
    li    t0, 0x4641554c
    sw    t0, 0(t1)
    csrr  t0, mcause
    sw    t0, 0(t1)
    csrr  t0, mepc
    sw    t0, 0(t1)
    csrr  t0, mtval
    sw    t0, 0(t1)
    csrr  t0, minstret
    sw    t0, 0(t1)

    // Exit simulation with failure code 1
    li    t1, 0xc0000008
    li    t0, 1
    sw    t0, 0(t1)
    li    t0, 0
    li    t1, 0
fault_loop:
    wfi
    j     fault_loop

handle_ecall:
    // Check syscall number in t0 (saved on stack at 0(sp))
    lw    t0, 0(sp)
    li    t1, 1
    bne   t0, t1, handle_fault

handle_halt:
    // Normal HALT:
    // Report HALT to testbench print port (0xc0000004):
    // TAG_HALT (0x48414c54 "HALT"), a0, minstret, mcycle
    li    t1, 0xc0000004
    li    t0, 0x48414c54
    sw    t0, 0(t1)
    sw    a0, 0(t1)
    csrr  t0, minstret
    sw    t0, 0(t1)
    csrr  t0, mcycle
    sw    t0, 0(t1)

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

    // Exit simulation with exit code from a0
    li    t1, 0xc0000008
    sw    a0, 0(t1)
    li    t1, 0
halt_loop:
    wfi
    j     halt_loop
