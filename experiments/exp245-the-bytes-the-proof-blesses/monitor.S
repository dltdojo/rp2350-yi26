// SPDX-License-Identifier: Apache-2.0
//
// exp245 — the bytes the proof blesses (monitor.S)
//
// exp240's monitor, word for word, with three charms added. Each is marked: a block between
// `// [Charm N] {` and `// [Charm N] }` is added, and a line that ends `// [Charm N] exp240: X` is exp240's
// line X changed. monitor.py takes the marks away (`ablate`) and requires exp240's monitor.bin, byte for
// byte, with all three gone and with each one alone gone.
//
//   [Charm 1] the shrine seal (18 words). Boot writes 0x4d414d4f and 0x4941554b at 0x80008010, which read
//             as the bytes "OMAMKUAI"; before reporting a HALT, the handler checks both words and reports a
//             FAULT if either differs. U-mode cannot reach the shrine, and boot rewrites it every round.
//   [Charm 2] the shadowed entry (2 more words). Entry 3 is read-only over the seed window
//             [0x80010100, 0x80010200): pmpaddr3 = 0x2000405f, pmpcfg0 = 0x191b1b1d. It lies wholly inside
//             entry 1, the data, which is tried first and lets a store in.
//   [Charm 3] the ceremonial scrub (7 words). Every exit zeroes the 32-byte slot [0x80010e00, 0x80010e20)
//             in the data, and nothing else of the payload's memory.
//
// Each has a theorem of its own in proof/, and an exposure theorem that says what it does not do.
// The rest of this header is exp240's.
//
// exp236's M-mode micro-monitor, with a different box. exp236 fences the payload into 64 KiB
// [0x80010000, 0x80020000) with one RWX entry, so a payload that can write a byte can also run it, and a stray
// pointer can rewrite the payload's own instructions. This one uses three of the four PMP entries, tried in order:
//
//   entry 0  code   [0x80010000, 0x80010080)  128 bytes   R-X  pmpaddr0 0x2000400f  cfg 0x1d
//   entry 1  data   [0x80010000, 0x80011000)  4 KiB       RW-  pmpaddr1 0x200041ff  cfg 0x1b
//   entry 2  stack  [0x8001f000, 0x80020000)  4 KiB       RW-  pmpaddr2 0x20007dff  cfg 0x1b
//   entry 3  off (here: the seed window, read-only, [Charm 2])                 cfg 0x00
//
// pmpcfg0 = 0x001b1b1d. The lowest-numbered entry that touches an access decides it, so the code entry, listed first,
// carves its 128 bytes out of the data entry that surrounds it: a store into the code matches entry 0, which has no
// W, and is refused; a jump into the data matches entry 1, which has no X, and is refused. No byte is both writable
// and executable. [0x80011000, 0x8001f000) matches nothing, and U-mode that matches nothing is refused: a guard
// region of 52 KiB between the data and the stack.
//
// The layout is the one a position-independent payload wants: exp225's Rule 30 kernel finds its own address with
// `auipc`, reads its seed at +0x100 and writes its history at +0x200..+0x600 -- inside the data entry, past its own
// 76 bytes of code. Everything else is exp236's, word for word but for the addresses that move with the seven words
// the entries add to boot and the one more that boot spends on writing every CSR it has (below, after `mepc`): a boot
// that reads nothing from the CSRs it finds is one that a previous round cannot reach.
//
//   1. Configures PMP as above, leaving all other physical memory in default-deny.
//   2. Clears all general purpose registers and initializes U-mode stack: sp = 0x80020000, the top of the stack entry.
//   3. Switches to User mode via mret with precise counter unfreezing.
//   4. On ecall (t0 = 1): reports HALT with exit code and cycle counts,
//      then scrubs and halts.
//   5. On fault (PMP violation, illegal CSR, bad syscall, etc.): catches the trap,
//      reports FAULT with mcause, mepc, mtval and minstret, sets a0 = 1, then
//      scrubs and halts by the same tail as HALT.
//
// The scrub (scrub_exit) zeroes x1..x9 and x11..x31, the two words the trap entry
// saved on the M-mode stack, and mscratch (which holds the payload's sp). It does
// not touch the payload region: memory the payload wrote stays where it is.

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

    // [Charm 1] {
    // Enshrine the seal: 0x80008010..0x80008017 read as "OMAMKUAI", outside every PMP entry
    li    t0, 0x80008010
    li    t1, 0x4d414d4f
    sw    t1, 0(t0)
    li    t1, 0x4941554b
    sw    t1, 4(t0)
    // [Charm 1] }

    // Freeze hardware counters during boot
    csrwi mcountinhibit, 5

    // Configure PMP entry 0, the code: 128 bytes NAPOT at 0x80010000 (0x2000400f)
    li    t0, 0x2000400f
    csrw  pmpaddr0, t0
    // Entry 1, the data: 4 KiB NAPOT at 0x80010000 (0x200041ff)
    li    t0, 0x200041ff
    csrw  pmpaddr1, t0
    // Entry 2, the stack: 4 KiB NAPOT at 0x8001f000 (0x20007dff)
    li    t0, 0x20007dff
    csrw  pmpaddr2, t0
    // PMP cfg: entry 0 NAPOT (0b11), R=1, W=0, X=1 (0x1d); entries 1 and 2 NAPOT, R=1, W=1, X=0 (0x1b);
    // entry 3 OFF
    li    t0, 0x191b1b1d                    // [Charm 2] exp240: li    t0, 0x001b1b1d
    csrw  pmpcfg0, t0

    // Setup payload entry point in mepc (0x80010000)
    li    t0, 0x80010000
    csrw  mepc, t0

    // mstatus all zero: MPP User mode (0b00), MIE and MPIE off, whatever it held before.
    // exp236 cleared MPP alone, with three words; this is one.
    csrw  mstatus, zero

    // The CSRs boot does not otherwise set, set too, so that nothing in them comes from
    // before the reset: entry 3's address, and the cause and value of the last trap
    // [Charm 2] {
    // Entry 3, the seed window, read-only: 256 bytes NAPOT at 0x80010100 (0x2000405f), inside entry 1
    li    t0, 0x2000405f
    // [Charm 2] }
    csrw  pmpaddr3, t0                      // [Charm 2] exp240: csrw  pmpaddr3, zero
    csrw  mcause, zero
    csrw  mtval, zero

    // Zero hardware performance counters
    csrw  minstret, zero
    csrw  minstreth, zero
    csrw  mcycle, zero
    csrw  mcycleh, zero

    // Initialize U-mode stack pointer (top of the stack entry: 0x80020000)
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
    // [Charm 1] {
    // Check the seal before a HALT: either word wrong, and it is a FAULT
    li    t2, 0x80008010
    lw    t0, 0(t2)
    li    t1, 0x4d414d4f
    bne   t0, t1, handle_fault
    lw    t0, 4(t2)
    li    t1, 0x4941554b
    bne   t0, t1, handle_fault
    // [Charm 1] }
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

    // [Charm 3] {
    // The sacred key slot, [0x80010e00, 0x80010e20): zeroed on every exit
    li    t0, 0x80010e00
    li    t1, 0x80010e20
scrub_slot:
    sw    zero, 0(t0)
    addi  t0, t0, 4
    bne   t0, t1, scrub_slot
    // [Charm 3] }

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
