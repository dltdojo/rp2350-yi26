/* SPDX-License-Identifier: Apache-2.0 */
/* exp209 — the RTL: the same shell, in the testbench's RAM below the region. */
ENTRY(_start)
SECTIONS
{
    . = 0x80000000;
    .text : { KEEP(*(.text.entry)) *(.text.harness) *(.text*) *(.rodata*) *(.srodata*) }
    .data : { *(.data*) *(.sdata*) }
    .bss : { __bss_start = .; *(.bss*) *(.sbss*) *(COMMON); . = ALIGN(4); __bss_end = .; }
    ASSERT(. <= 0x8000F000, "the shell has grown into its own stack")
}
