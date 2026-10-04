/* SPDX-License-Identifier: Apache-2.0 */
/* exp202 — a test is one flat image at the region's base: code, then data. */
ENTRY(_start)
SECTIONS
{
    . = 0x80010000;
    .text : { *(.text.init) *(.text*) }
    .data : { *(.data*) *(.sdata*) *(.rodata*) *(.srodata*) }
    .bss : { *(.bss*) *(.sbss*) }
    ASSERT(. <= 0x80018000, "a test is larger than half the region")
}
