// SPDX-License-Identifier: Apache-2.0
//
// exp239 — the scratch the monitor scrubs (monitor.S)
//
// exp236's M-mode micro-monitor, with one addition: before it zeroes the registers, it zeroes the
// payload's memory.
//
//   1. Boot, the trap vector, HALT and the fault report are exp236's, word for word, up to
//      `scrub_exit` at 0x800001a0.
//   2. scrub_exit clears the two words trap entry saved and mscratch, as exp236's does, and then:
//        a. zeroes the confidential scratch, [0x80012200, 0x80014000) -- the SHA-256 schedule and
//           the raw samples of exp223's kernel -- on EVERY exit;
//        b. zeroes the 32-byte digest window, [0x80012140, 0x80012160), too, unless the exit is a
//           clean HALT: a0 is the exit code, and a fault sets it to 1, so a0 != 0 covers a failed
//           health test, any other nonzero HALT, and every trap. Only a payload that halted with
//           0 leaves a digest behind.
//      then zeroes x1..x9 and x11..x31 and parks, as exp236's does.
//
// The two loops are the same three words: store a zero, step four bytes, loop until the end.

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

    // Failure code 1 in a0, then the same tail as HALT
    li    a0, 1
    j     scrub_exit

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

scrub_exit:
    // The two words trap entry saved on the M-mode stack held U-mode's t0 and t1;
    // mscratch holds U-mode's sp.
    sw    zero, 0(sp)
    sw    zero, 4(sp)
    csrw  mscratch, zero

    // The payload's confidential scratch, [0x80012200, 0x80014000): on every exit.
    lui   t0, 0x80012
    addi  t0, t0, 0x200
    lui   t1, 0x80014
scrub_conf:
    sw    zero, 0(t0)
    addi  t0, t0, 4
    bne   t0, t1, scrub_conf

    // The digest window, [0x80012140, 0x80012160): unless this is a HALT with a0 = 0.
    beqz  a0, scrub_regs
    lui   t0, 0x80012
    addi  t0, t0, 0x140
    addi  t1, t0, 32
scrub_digest:
    sw    zero, 0(t0)
    addi  t0, t0, 4
    bne   t0, t1, scrub_digest

scrub_regs:
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
