// SPDX-License-Identifier: Apache-2.0
//
// tools/hazard3/shell — where the chip starts, in flash at 0x10000000.
//
// The first word jumps to _start, and the IMAGE_DEF block right after it also
// names _start as the entry point: whichever of the two the bootrom goes by,
// it arrives at the same instruction. The block's words are the ones
// embassy-rp's block.rs builds (`item_generic_1bs`, `item_last`):
//
//   0xffffded3   start marker
//   0x11010142   IMAGE_TYPE: EXE | CPU RISC-V | CHIP RP2350, one word
//   0x00000344   ENTRY_POINT, three words: pc, then sp
//   _start       pc
//   MSTACK       sp
//   0x000004ff   last item, four words of items before it
//   0x00000000   link to the next block: a one-block loop links to itself
//   0xab123579   end marker
//
// MSTACK is the build's (-DMSTACK): the top of the Machine-mode stack, which
// the shell's builds put at the region's base.

.section .text.entry, "ax"
.globl _entry
_entry:
    j     _start

.balign 4
    .word 0xffffded3
    .word 0x11010142
    .word 0x00000344
    .word _start
    .word MSTACK
    .word 0x000004ff
    .word 0x00000000
    .word 0xab123579

.globl _start
_start:
    li    sp, MSTACK
    // A trap from here on reaches `handle`, which tells a shell fault from a
    // payload's trap by mstatus.MPP.
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
