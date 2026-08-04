/* exp139 — the partition table takes flash offset 0, so the image moves.
 *
 * The RP2350's ROM looks for a block loop at the start of flash. That is
 * either an IMAGE_DEF (a normal firmware) or a PARTITION_TABLE. They cannot
 * both be there, which is why writing a table means relocating the firmware.
 *
 * Everything below is rp2350-linker's own script with two changes: a 4 KiB
 * region at the very start for the table, and FLASH beginning after it.
 */
MEMORY
{
    PT    : ORIGIN = 0x10000000, LENGTH = 4K
    FLASH : ORIGIN = 0x10001000, LENGTH = 4092K
    RAM   : ORIGIN = 0x20000000, LENGTH = 512K
}

SECTIONS {
    /* The table, at the one address the ROM looks for it. */
    .partition_table ORIGIN(PT) : ALIGN(4)
    {
        KEEP(*(.partition_table));
        . = ALIGN(4);
    } > PT

    /* Bloc de démarrage requis par le BootROM du RP2350 */
    .start_block : ALIGN(4)
    {
        __start_block_addr = .;
        KEEP(*(.start_block));
        KEEP(*(.boot_info));
    } > FLASH

    .bi_entries : ALIGN(4)
    {
        __bi_entries_start = .;
        KEEP(*(.bi_entries));
        . = ALIGN(4);
        __bi_entries_end = .;
    } > FLASH
} INSERT AFTER .vector_table;

_stext = ADDR(.start_block) + SIZEOF(.start_block);
