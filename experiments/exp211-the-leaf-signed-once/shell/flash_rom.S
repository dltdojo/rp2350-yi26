// SPDX-License-Identifier: Apache-2.0
//
// exp211 — one flash operation through the bootrom, from SRAM. Once
// flash_exit_xip has run, flash is a device and no longer memory: nothing may
// be fetched from it until flash_enter_cmd_xip has run again. So this
// routine is assembled into flash but copied to SRAM and run from there, and
// it uses nothing but registers, the stack (in SRAM) and the call block a0
// points at (in SRAM): position-independent, so the copy runs as it is.
//
// The sequence is the bootrom's own advice for its low-level flash API
// (RP2350 datasheet, as embassy-rp's rom_data/rp235x.rs quotes it), the same
// order embassy-rp's write_flash_inner uses: connect_internal_flash,
// flash_exit_xip, the operation, flash_flush_cache, then back to XIP. For
// the last step embassy-rp runs the XIP setup function the bootrom left in
// boot RAM; this calls the bootrom's flash_enter_cmd_xip instead, which
// embassy-rp names as the fallback: plain 03h serial reads, slower and safe.
//
// The call block, nine words:
//
//    0  connect_internal_flash      16  a1
//    4  flash_exit_xip              20  a2
//    8  the operation               24  a3
//   12  a0                          28  flash_flush_cache
//                                   32  flash_enter_cmd_xip

.section .text.flash_rom, "ax"
.globl flash_rom_call
.globl flash_rom_call_end
.balign 4
flash_rom_call:
    addi  sp, sp, -16
    sw    ra, 12(sp)
    sw    s0, 8(sp)
    mv    s0, a0
    lw    t0, 0(s0)
    jalr  ra, 0(t0)
    lw    t0, 4(s0)
    jalr  ra, 0(t0)
    lw    a0, 12(s0)
    lw    a1, 16(s0)
    lw    a2, 20(s0)
    lw    a3, 24(s0)
    lw    t0, 8(s0)
    jalr  ra, 0(t0)
    lw    t0, 28(s0)
    jalr  ra, 0(t0)
    lw    t0, 32(s0)
    jalr  ra, 0(t0)
    lw    s0, 8(sp)
    lw    ra, 12(sp)
    addi  sp, sp, 16
    ret
.balign 4
flash_rom_call_end:
