// SPDX-License-Identifier: Apache-2.0
//
// exp203 — what Hazard3's minstret counts, one instruction at a time.
//
// A Machine-mode program of its own, run with `tools/hazard3/sim.sh bare`: no
// harness, so nothing else is counted. Each measurement zeroes minstret with
// counting held, lets it run over exactly the instructions named, and prints
// what it read. The read is the first thing that happens after them — for the
// User-mode cases, the trap handler's first instruction — so the reading
// instruction itself is never in the number.
//
//   1  enable; read                    is the enabling write counted?
//   2  enable; disable; read           is the disabling write counted?
//   3  enable; nop; disable; read      one ordinary instruction, for scale
//   4  enable; mret to Machine         one mret
//   5  enable; mret to User; ecall     one mret and one ecall from User mode
//   6  enable; mret to User; csrr      one mret and one illegal instruction
//   7  enable; mret to User; nop; ecall
//
// Printed in that order, one hex word each, to the testbench's print port.
//
// From 4 on, the read is not the instruction right after the event: four
// counted `nop`s come first, and the number printed has them taken off. A read
// at the very first instruction of a trap handler was found to return one
// less when the handler happened to sit right after the `mret` in memory —
// already fetched — than when it did not. Where the reading happens is a
// property of the pipeline, not of the count, so it is kept out of it.
//
// Built twice by measure.sh: as written, and with -DADJACENT, which moves the
// trap handler to sit directly behind the mret that enters User mode. Nothing
// a measurement executes changes between the two; only what lies behind the
// mret in memory does.

.equ IO, 0xc0000000

.section .text
.org 0x40
_start:
    li    s1, IO
    la    t0, handler
    csrw  mtvec, t0
    li    t0, -1                 // PMP entry 0: all of memory, R|W|X, for User mode
    csrw  pmpaddr0, t0
    li    t0, 0x1f
    csrw  pmpcfg0, t0
    csrwi mcountinhibit, 5

    // 1
    csrw  minstret, zero
    csrwi mcountinhibit, 0
    csrr  a5, minstret
    csrwi mcountinhibit, 5
    sw    a5, 4(s1)
    // 2
    csrw  minstret, zero
    csrwi mcountinhibit, 0
    csrwi mcountinhibit, 5
    csrr  a5, minstret
    sw    a5, 4(s1)
    // 3
    csrw  minstret, zero
    csrwi mcountinhibit, 0
    nop
    csrwi mcountinhibit, 5
    csrr  a5, minstret
    sw    a5, 4(s1)
    // 4
    li    t0, 0x1800
    csrs  mstatus, t0            // MPP = Machine
    la    t0, m4
    csrw  mepc, t0
    csrw  minstret, zero
    csrwi mcountinhibit, 0
    mret
m4: nop
    nop
    nop
    nop
    csrr  a5, minstret
    csrwi mcountinhibit, 5
    addi  a5, a5, -4
    sw    a5, 4(s1)
    // 5
    la    s0, after5
    la    t0, u5
    jal   x0, to_user
after5:
    // 6
    la    s0, after6
    la    t0, u6
    jal   x0, to_user
after6:
    // 7
    la    s0, after7
    la    t0, u7
    jal   x0, to_user
after7:
    sw    zero, 8(s1)            // exit 0

// mret into User mode at t0, counting from the mret on.
to_user:
    csrw  mepc, t0
    li    t0, 0x1800
    csrc  mstatus, t0            // MPP = User
    csrw  minstret, zero
    csrwi mcountinhibit, 0
    mret
#ifdef ADJACENT
// The handler right behind the mret: what the frontend fetches after an mret
// is then the handler itself.
handler:
    nop
    nop
    nop
    nop
    csrr  a5, minstret
    csrwi mcountinhibit, 5
    addi  a5, a5, -4
    sw    a5, 4(s1)
    jalr  x0, 0(s0)
#endif

u5: ecall
u6: csrr  a0, mstatus
u7: nop
    ecall

#ifndef ADJACENT
.balign 4
handler:
    nop
    nop
    nop
    nop
    csrr  a5, minstret
    csrwi mcountinhibit, 5
    addi  a5, a5, -4
    sw    a5, 4(s1)
    jalr  x0, 0(s0)
#endif
