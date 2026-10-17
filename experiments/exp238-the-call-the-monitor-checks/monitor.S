// SPDX-License-Identifier: Apache-2.0
//
// exp238 — the micro-monitor that answers calls (monitor.S)
//
// exp236's monitor, taught two calls that do not stop the payload. It is a new program,
// not exp236's: none of exp236's Lean theorems are about these words.
//
//   ecall t0 = 1  HALT      as in exp236: report, scrub, park.
//   ecall t0 = 2  HASHB     a0 = input, a1 = length, a2 = output (32 bytes).
//   ecall t0 = 3  CHECKSIG  a0 = key (32 bytes), a1 = signature (64 bytes); a0 <- 1 or 0.
//   anything else           a fault, as in exp236.
//
// The monitor does not hash and does not verify: it holds no SHA-256 and no secp256k1.
// What it owns is the *pointers*. A payload that hands `ptr, len` to a service that runs
// with M-mode's authority is asking that service to read and write on its behalf, and the
// PMP does not stop M-mode. So before anything is forwarded, every range the call names
// is checked to lie wholly inside the payload's box [BOX_LO, BOX_HI), and a range that does
// not — including one whose end wraps past 2^32 — is a fault: report, scrub, park.
//
// The check is three comparisons, none of which adds ptr and len:
//
//     ptr >= BOX_LO           bltu a0, lo        -> fault
//     ptr <= BOX_HI           bltu hi, a0        -> fault   (so hi - ptr cannot go below 0)
//     len <= BOX_HI - ptr     bltu (hi - ptr), len -> fault
//
// An accepted call is forwarded to the service port (0xc0000010): three argument words
// and then the call number, whose write is the request; a read of the same word is the
// answer. The service is the host's — the testbench here, a C caller on the chip — and
// is trusted with nothing: it only ever sees ranges the monitor has already confined.
//
// The call then returns: mepc <- mepc + 4, the payload's t0..t3 back, sp swapped back,
// counters released, mret. The monitor spends t0..t3 and nothing else, so the payload's
// other registers are never touched; the trap entry saves exactly those four.
//
// Counters: the first instruction of the handler freezes them and the last two before
// mret release them, so a call costs the payload's minstret exactly three — the ecall,
// the `csrwi` that releases the counters, and the `mret` — whatever the call and whatever
// the service did.

.section .text.entry, "ax"
.globl _start
.globl _reset
.globl trap_handler

.org 0
_start:
    j _reset

.org 0x40
_reset:
    la    t0, trap_handler
    csrw  mtvec, t0

    li    t0, 0x80008000
    csrw  mscratch, t0

    csrwi mcountinhibit, 5

    // PMP entry 0: 64 KiB NAPOT at 0x80010000, RWX, unlocked.
    li    t0, 0x20005fff
    csrw  pmpaddr0, t0
    li    t0, 0x1f
    csrw  pmpcfg0, t0

    li    t0, 0x80010000
    csrw  mepc, t0

    li    t0, 0x1800
    csrc  mstatus, t0

    csrw  minstret, zero
    csrw  minstreth, zero
    csrw  mcycle, zero
    csrw  mcycleh, zero

    li    sp, 0x80020000

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
    // Freeze the counters first: nothing the monitor does is the payload's.
    csrwi mcountinhibit, 5

    // sp <-> mscratch: sp is the M-mode stack, mscratch the payload's sp.
    csrrw sp, mscratch, sp

    // The four registers the monitor spends, the payload's, saved.
    sw    t0, 0(sp)
    sw    t1, 4(sp)
    sw    t2, 8(sp)
    sw    t3, 12(sp)

    csrr  t0, mcause
    li    t1, 8                     // environment call from U-mode
    beq   t0, t1, handle_ecall

handle_fault:
    li    t1, 0xc0000004
    li    t0, 0x4641554c            // "FAUL"
    sw    t0, 0(t1)
    csrr  t0, mcause
    sw    t0, 0(t1)
    csrr  t0, mepc
    sw    t0, 0(t1)
    csrr  t0, mtval
    sw    t0, 0(t1)
    csrr  t0, minstret
    sw    t0, 0(t1)
    li    a0, 1
    j     scrub_exit

handle_ecall:
    lw    t0, 0(sp)                 // the payload's t0: the call number
    li    t1, 1
    beq   t0, t1, handle_halt
    li    t1, 2
    beq   t0, t1, call_hashb
    li    t1, 3
    beq   t0, t1, call_checksig
    j     handle_fault

call_hashb:
    // input [a0, a0 + a1), output [a2, a2 + 32)
    lui   t1, 0x80010               // BOX_LO
    lui   t2, 0x80020               // BOX_HI
    bltu  a0, t1, handle_fault
    bltu  t2, a0, handle_fault
    sub   t3, t2, a0
    bltu  t3, a1, handle_fault
    bltu  a2, t1, handle_fault
    bltu  t2, a2, handle_fault
    sub   t3, t2, a2
    li    t0, 32
    bltu  t3, t0, handle_fault
    li    t3, 0xc0000010
    sw    a0, 0(t3)
    sw    a1, 4(t3)
    sw    a2, 8(t3)
    li    t0, 2
    sw    t0, 12(t3)                // the request
    j     trap_return

call_checksig:
    // key [a0, a0 + 32), signature [a1, a1 + 64)
    lui   t1, 0x80010
    lui   t2, 0x80020
    bltu  a0, t1, handle_fault
    bltu  t2, a0, handle_fault
    sub   t3, t2, a0
    li    t0, 32
    bltu  t3, t0, handle_fault
    bltu  a1, t1, handle_fault
    bltu  t2, a1, handle_fault
    sub   t3, t2, a1
    li    t0, 64
    bltu  t3, t0, handle_fault
    li    t3, 0xc0000010
    sw    a0, 0(t3)
    sw    a1, 4(t3)
    li    t0, 3
    sw    t0, 12(t3)                // the request
    lw    a0, 12(t3)                // the answer: 1 or 0

trap_return:
    // Past the ecall.
    csrr  t0, mepc
    addi  t0, t0, 4
    csrw  mepc, t0
    // The payload's t0..t3 back (a0 is the answer, if there was one).
    lw    t0, 0(sp)
    lw    t1, 4(sp)
    lw    t2, 8(sp)
    lw    t3, 12(sp)
    // sp <-> mscratch again: the payload's sp back, the M-mode stack in mscratch.
    csrrw sp, mscratch, sp
    // Release the counters and go: this and the mret are the call's two extra instructions.
    csrwi mcountinhibit, 0
    mret

handle_halt:
    li    t1, 0xc0000004
    li    t0, 0x48414c54            // "HALT"
    sw    t0, 0(t1)
    sw    a0, 0(t1)
    csrr  t0, minstret
    sw    t0, 0(t1)
    csrr  t0, mcycle
    sw    t0, 0(t1)

scrub_exit:
    // The four words trap entry saved held the payload's t0..t3; mscratch the payload's sp.
    sw    zero, 0(sp)
    sw    zero, 4(sp)
    sw    zero, 8(sp)
    sw    zero, 12(sp)
    csrw  mscratch, zero

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

    li    t1, 0xc0000008
    sw    a0, 0(t1)
    li    t1, 0
halt_loop:
    wfi
    j     halt_loop
