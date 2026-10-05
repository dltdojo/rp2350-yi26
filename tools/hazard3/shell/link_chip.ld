/* SPDX-License-Identifier: Apache-2.0 */
/* tools/hazard3/shell — the chip: code and constants in flash from 0x10000000,
   nothing written there at run time. FLASH_SIZE is the build's
   (-Wl,--defsym=FLASH_SIZE=...): exp209 holds itself to sector 0, 4096 bytes,
   and the link refuses an image that has outgrown what the build allows. */
ENTRY(_entry)
MEMORY
{
    FLASH (rx)  : ORIGIN = 0x10000000, LENGTH = FLASH_SIZE
    RAM   (rwx) : ORIGIN = 0x20000000, LENGTH = 0x60000
}
SECTIONS
{
    .text : { KEEP(*(.text.entry)) *(.text.harness) *(.text*) *(.rodata*) *(.srodata*) *(.above*) } > FLASH
    .data : { *(.data*) *(.sdata*) } > RAM AT > FLASH
    .bss (NOLOAD) : { __bss_start = .; *(.bss*) *(.sbss*) *(COMMON); . = ALIGN(4); __bss_end = .; } > RAM
    ASSERT(SIZEOF(.data) == 0, "initialised data would need copying out of flash; the shell has none")
}
