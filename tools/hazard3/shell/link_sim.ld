/* SPDX-License-Identifier: Apache-2.0 */
/* tools/hazard3/shell — the RTL: the same shell, in the testbench's RAM below
   the region; constants too big to fit there (section .above) go above it,
   since the testbench has 16 MiB. */
ENTRY(_start)
SECTIONS
{
    . = 0x80000000;
    .text : { KEEP(*(.text.entry)) *(.text.harness) *(.text*) *(.rodata*) *(.srodata*) }
    .data : { *(.data*) *(.sdata*) }
    .bss : { __bss_start = .; *(.bss*) *(.sbss*) *(COMMON); . = ALIGN(4); __bss_end = .; }
    ASSERT(. <= 0x8000F000, "the shell has grown into its own stack")
    .above 0x80020000 : { *(.above*) }
}
