/* SPDX-License-Identifier: Apache-2.0 */
/* tools/hazard3/harness — the shell lives below the payload's region. */
ENTRY(_reset)
SECTIONS
{
    . = 0x80000000;
    .text : { KEEP(*(.text.entry)) *(.text*) }
    .rodata : { *(.rodata*) *(.srodata*) }
    .data : { *(.data*) *(.sdata*) }
    .bss : { *(.bss*) *(.sbss*) *(COMMON) }
    ASSERT(. <= 0x8000F000, "the harness has grown into its own stack")
}
