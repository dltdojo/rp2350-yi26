/* SPDX-License-Identifier: Apache-2.0 */
/* exp209 — the chip: code in flash sector 0, nothing written there at run time. */
ENTRY(_entry)
MEMORY
{
    FLASH (rx)  : ORIGIN = 0x10000000, LENGTH = 4K
    RAM   (rwx) : ORIGIN = 0x20000000, LENGTH = 0x60000
}
SECTIONS
{
    .text : { KEEP(*(.text.entry)) *(.text.harness) *(.text*) *(.rodata*) *(.srodata*) } > FLASH
    .data : { *(.data*) *(.sdata*) } > RAM AT > FLASH
    .bss (NOLOAD) : { __bss_start = .; *(.bss*) *(.sbss*) *(COMMON); . = ALIGN(4); __bss_end = .; } > RAM
    ASSERT(SIZEOF(.data) == 0, "initialised data would need copying out of flash; the shell has none")
}
