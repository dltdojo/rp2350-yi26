// SPDX-License-Identifier: Apache-2.0
//
// tools/hazard3/harness — the shell, for the simulated core.
//
// What the RP2350 shell will do in Rust, done here in as few instructions as
// will do it, so that a payload runs on the Hazard3 RTL under exactly the
// conditions the Lean model assumes:
//
//   - the payload is at REGION, 64 KiB, and PMP entry 0 gives User mode read,
//     write and execute there and nowhere else (no matching entry is a fault
//     for User mode);
//   - it is entered with `mret` into User mode, every register zero except
//     `sp`, which is the top of the region;
//   - interrupts are off: mie is zero, and User mode ignores mstatus.MIE;
//   - minstret and mcycle are held by mcountinhibit everywhere except while
//     the payload runs, and zeroed before it starts.
//
// Every trap lands in `trap`, which saves the payload's registers and calls
// `handle` in handler.c. That decides HASH, HALT or fault, and either
// returns (to `mret` back into the payload) or ends the simulation.
//
// The image is this, padded to REGION - MEM_BASE bytes, then the payload.

// The addresses are the testbench's unless a build says otherwise: exp209's
// chip shell includes this file with -DSHELL and its own REGION and MSTACK, so
// that the instructions around the payload — the ones minstret counts — are
// these exact ones on silicon too.
#ifndef REGION
#define REGION      0x80010000
#endif
#define REGION_SIZE 0x00010000
#ifndef MSTACK
#define MSTACK      REGION        // M-mode stack: grows down from the region's base
#endif

#ifndef SHELL
.section .text.entry, "ax"
.globl _reset

// mtvec resets to the start of RAM; anything that traps before mtvec is set
// lands here and goes to the handler anyway.
.org 0
    j trap

// The reset vector of the testbench's configuration.
.org 0x40
_reset:
#else
// Under a shell, its own startup has run first and calls this; it does not
// return. The payload's first trap lands in `trap` and calls the shell's
// `handle`.
.section .text.harness, "ax"
.globl enter_payload
.globl trap
.balign 4
enter_payload:
#endif
    la    t0, trap
    csrw  mtvec, t0
    li    sp, MSTACK

    // Hold both counters while the shell runs.
    csrwi mcountinhibit, 5

    // PMP entry 0: NAPOT over the 64 KiB region, R|W|X, not locked — so it
    // binds User mode and leaves Machine mode alone.
    li    t0, (REGION >> 2) | ((REGION_SIZE >> 3) - 1)
    csrw  pmpaddr0, t0
    li    t0, 0x1f
    csrw  pmpcfg0, t0

    csrw  mie, zero
    li    t0, 0x1800          // mstatus.MPP = User
    csrc  mstatus, t0
    li    t0, REGION
    csrw  mepc, t0

    csrw  minstret, zero
    csrw  minstreth, zero
    csrw  mcycle, zero
    csrw  mcycleh, zero

    li    sp, REGION + REGION_SIZE
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
    // From here to the payload's first instruction: these two.
    csrwi mcountinhibit, 0
    mret

// The payload's registers go to `saved`, x0 included so that saved[n] is xn.
.balign 4
trap:
    csrwi mcountinhibit, 5
    csrw  mscratch, sp
    la    sp, saved
    sw    x1, 4(sp)
    sw    x3, 12(sp)
    sw    x4, 16(sp)
    sw    x5, 20(sp)
    sw    x6, 24(sp)
    sw    x7, 28(sp)
    sw    x8, 32(sp)
    sw    x9, 36(sp)
    sw    x10, 40(sp)
    sw    x11, 44(sp)
    sw    x12, 48(sp)
    sw    x13, 52(sp)
    sw    x14, 56(sp)
    sw    x15, 60(sp)
    sw    x16, 64(sp)
    sw    x17, 68(sp)
    sw    x18, 72(sp)
    sw    x19, 76(sp)
    sw    x20, 80(sp)
    sw    x21, 84(sp)
    sw    x22, 88(sp)
    sw    x23, 92(sp)
    sw    x24, 96(sp)
    sw    x25, 100(sp)
    sw    x26, 104(sp)
    sw    x27, 108(sp)
    sw    x28, 112(sp)
    sw    x29, 116(sp)
    sw    x30, 120(sp)
    sw    x31, 124(sp)
    csrr  t0, mscratch
    sw    t0, 8(sp)
    li    sp, MSTACK
    la    a0, saved
    call  handle
    // handle returned: back into the payload.
    la    sp, saved
    lw    x1, 4(sp)
    lw    x3, 12(sp)
    lw    x4, 16(sp)
    lw    x5, 20(sp)
    lw    x6, 24(sp)
    lw    x7, 28(sp)
    lw    x8, 32(sp)
    lw    x9, 36(sp)
    lw    x10, 40(sp)
    lw    x11, 44(sp)
    lw    x12, 48(sp)
    lw    x13, 52(sp)
    lw    x14, 56(sp)
    lw    x15, 60(sp)
    lw    x16, 64(sp)
    lw    x17, 68(sp)
    lw    x18, 72(sp)
    lw    x19, 76(sp)
    lw    x20, 80(sp)
    lw    x21, 84(sp)
    lw    x22, 88(sp)
    lw    x23, 92(sp)
    lw    x24, 96(sp)
    lw    x25, 100(sp)
    lw    x26, 104(sp)
    lw    x27, 108(sp)
    lw    x28, 112(sp)
    lw    x29, 116(sp)
    lw    x30, 120(sp)
    lw    x31, 124(sp)
    lw    sp, 8(sp)
    csrwi mcountinhibit, 0
    mret

.section .bss
.balign 4
.globl saved
saved: .space 128
