//! The block the RP2350's boot ROM reads at flash offset 0.
//!
//! [exp138](../../../experiments/exp138-what-the-rom-already-knows/) asked a
//! stock board what it knew about firmware slots and got the same answer three
//! ways: the machinery is in the ROM, and there is nothing in it. This crate
//! is the something.
//!
//! # Why this is not `embassy_rp::block`
//!
//! That module has the types, the item IDs and the flag names, and this crate
//! uses none of them at run time — because a `PartitionTableBlock` **cannot be
//! placed at an address**. Its words are private with no accessor, which is
//! correct for what it is for: firmware writing a table into flash while it
//! runs. A table that has to exist *before* any firmware runs has to be a
//! `[u32; N]` a linker section can hold.
//!
//! So the words are laid out here, and the layout is checked by tests rather
//! than trusted. [`crates/fat12`](../../fat12/) exists for the same reason one
//! layer up: a structure is an arrangement of bytes that other software has
//! agreed to interpret, and getting one wrong produces something that looks
//! fine until it does not work.
//!
//! # What a block is
//!
//! ```text
//!   0xffffded3   start marker
//!   …            items, each one word of header plus its data
//!   0x0000LLff   ITEM_2BS_LAST, carrying the length in words
//!   0x00000000   relative link to the next block — zero means this block
//!                loops to itself, which is what a one-block loop is
//!   0xab123579   end marker
//! ```
//!
//! # What is independently confirmed, and the one thing that is not
//!
//! The values here were mirrored from `embassy-rp`'s encoder and then checked
//! against the Pico SDK's own `picobin.h`. Twelve of them agree exactly: both
//! markers, all six permission bits, and all six family bits.
//!
//! **One does not, and it is the one that decides whether a board boots.**
//! The SDK defines `PICOBIN_BLOCK_ITEM_PARTITION_TABLE` as `0x0a` with no
//! `1BS`/`2BS` in the name, while its neighbours carry the width in theirs
//! (`ITEM_1BS_IMAGE_TYPE`, `ITEM_2BS_LAST`). `embassy-rp` puts `0x0a` under
//! *"these all have a 2-byte size"*, and this crate follows it — see
//! [`SIZE_FIELD_IS_UNCONFIRMED`] for what the alternative would be and why the
//! choice made here is the likelier one.
//!
//! That is not a reason to wait. It is a reason to write it down where whoever
//! is holding a board that will not enumerate can find it in one place.
//!
//! # What this crate will not do
//!
//! It does not write anything to flash, it has no opinion about A/B, and it
//! cannot tell you whether the ROM will accept what it produced. The only
//! thing that can answer that is a board.

#![cfg_attr(not(test), no_std)]

/// The Pico SDK calls it `PICOBIN_BLOCK_MARKER_START`.
pub const MARKER_START: u32 = 0xffff_ded3;

/// The Pico SDK calls it `PICOBIN_BLOCK_MARKER_END`.
pub const MARKER_END: u32 = 0xab12_3579;

/// Item ID for a partition table, two-byte size.
pub const ITEM_PARTITION_TABLE: u8 = 0x0a;

/// Item ID for the last item in a block, two-byte size.
pub const ITEM_LAST: u8 = 0xff;

/// 4 KiB, the unit every partition boundary is counted in.
pub const SECTOR: u32 = 4096;

/// The largest sector number a partition boundary can name.
///
/// `0x2000` sectors of 4 KiB is 32 MiB, which is the whole XIP window — not
/// the flash any particular board has fitted. A Pico 2 has 4 MiB, so a table
/// that names sector 2000 is well-formed and describes nothing.
pub const MAX_SECTOR: u16 = 0x1fff;

/// Permission bits, as the ROM reads them.
///
/// They appear in **both** of a partition's words. That is not redundancy in
/// the encoding — it is how the ROM can check a permission without having
/// decoded the rest of the entry.
pub mod permission {
    /// Readable in Secure mode.
    pub const SECURE_READ: u32 = 1 << 26;
    /// Writable in Secure mode.
    pub const SECURE_WRITE: u32 = 1 << 27;
    /// Readable in Non-Secure mode.
    pub const NON_SECURE_READ: u32 = 1 << 28;
    /// Writable in Non-Secure mode.
    pub const NON_SECURE_WRITE: u32 = 1 << 29;
    /// Readable from the bootloader — which is what BOOTSEL puts you in.
    pub const BOOT_READ: u32 = 1 << 30;
    /// Writable from the bootloader. Without this, a UF2 dragged onto the
    /// board's drive cannot land in this partition.
    pub const BOOT_WRITE: u32 = 1 << 31;

    /// All six. What the ROM itself defaults to for unpartitioned space.
    pub const ALL: u32 =
        SECURE_READ | SECURE_WRITE | NON_SECURE_READ | NON_SECURE_WRITE | BOOT_READ | BOOT_WRITE;
}

/// Which UF2 family IDs a partition will accept when one is dragged onto the
/// board.
///
/// A partition that accepts no family is a partition nothing can be flashed
/// into, and the failure is silent: the drag succeeds and the bytes go
/// somewhere else.
pub mod family {
    /// `rp2040`.
    pub const RP2040: u32 = 1 << 14;
    /// An absolute-addressed image, which is what the bootrom's own drive uses.
    pub const ABSOLUTE: u32 = 1 << 15;
    /// Data rather than code.
    pub const DATA: u32 = 1 << 16;
    /// `rp2350-arm-s` — what `elf2flash convert -b rp2350` produces, and what
    /// every firmware in this repository is.
    pub const RP2350_ARM_S: u32 = 1 << 17;
    /// `rp2350-riscv`.
    pub const RP2350_RISCV: u32 = 1 << 18;
    /// `rp2350-arm-ns`.
    pub const RP2350_ARM_NS: u32 = 1 << 19;

    /// The four the ROM defaults to accepting for unpartitioned space.
    ///
    /// Not a guess: exp138 read this set off a board that had never had a
    /// table written to it. See [`crate::tests`] — the value it printed is a
    /// test case here.
    pub const ROM_DEFAULTS: u32 = ABSOLUTE | DATA | RP2350_ARM_S | RP2350_RISCV;
}

/// The one field this crate could not confirm from a second source, and what
/// to try if a board does not boot.
///
/// A partition-table item's header carries a length. Whether that length is
/// **two bytes wide** (bits 8–23, value in bits 24–31) or **one byte wide**
/// (bits 8–15, value in bits 16–31) changes the first item word:
///
/// ```text
/// 0x0100040a   two-byte size — what this crate emits, following embassy-rp
/// 0x0001040a   one-byte size — the alternative
/// ```
///
/// The two-byte reading is the likelier one and this crate uses it, for a
/// structural reason rather than an authority: a partition table can hold
/// sixteen partitions of several words each, and a one-byte length caps an
/// item at 255 words. The other item the same encoder treats as two-byte —
/// a load map — is variable-length for the same reason.
///
/// **If a board flashed with a table from this crate does not enumerate**,
/// this word is the first thing to change, and
/// [`ONE_BYTE_SIZE_ALTERNATIVE`] is what to change it to.
pub const SIZE_FIELD_IS_UNCONFIRMED: bool = true;

/// The first item word a one-byte size field would produce, for the same
/// one-partition table. See [`SIZE_FIELD_IS_UNCONFIRMED`].
pub const ONE_BYTE_SIZE_ALTERNATIVE: u32 = 0x0001_040a;

/// One partition's two words.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Partition {
    /// Permissions, plus first and last sector.
    pub location: u32,
    /// Permissions, plus flags — families, bootability, and the rest.
    pub flags: u32,
}

impl Partition {
    /// A partition covering `first_sector..=last_sector`, inclusive.
    ///
    /// Inclusive because the ROM's encoding is: a partition of one sector has
    /// `first == last`, and there is no way to express an empty one.
    pub const fn new(first_sector: u16, last_sector: u16, permissions: u32, flags: u32) -> Self {
        assert!(first_sector <= MAX_SECTOR);
        assert!(last_sector <= MAX_SECTOR);
        assert!(first_sector <= last_sector);
        Self {
            location: permissions | ((last_sector as u32) << 13) | (first_sector as u32),
            flags: permissions | flags,
        }
    }

    /// The first and last sector this partition covers.
    pub const fn sectors(&self) -> (u16, u16) {
        (
            (self.location & 0x1fff) as u16,
            ((self.location >> 13) & 0x1fff) as u16,
        )
    }

    /// The first and last byte, as an offset into flash.
    pub const fn bytes(&self) -> (u32, u32) {
        let (first, last) = self.sectors();
        (first as u32 * SECTOR, (last as u32 + 1) * SECTOR - 1)
    }
}

/// Encode an item header with a two-byte size field.
pub const fn item(value: u8, length_words: u16, id: u8) -> u32 {
    ((value as u32) << 24) | ((length_words as u32) << 8) | (id as u32)
}

/// A block loop containing one partition table with a single partition.
///
/// Eight words, which is what the encoding comes to and not a round number
/// chosen for looks:
///
/// ```text
///   marker, item header, unpartitioned flags,
///   partition location, partition flags,
///   last item, link, marker
/// ```
pub const fn one_partition(unpartitioned_flags: u32, partition: Partition) -> [u32; 8] {
    // The item is four words: its own header, the unpartitioned flags, and the
    // partition's two. The `1` in the top byte is the partition count.
    let header = item(1, 4, ITEM_PARTITION_TABLE);
    [
        MARKER_START,
        header,
        unpartitioned_flags,
        partition.location,
        partition.flags,
        // The length here counts every word before this one except the start
        // marker, which is the convention the ROM's own reference builder uses.
        item(0, 4, ITEM_LAST),
        0,
        MARKER_END,
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The value a real board printed, decoded.
    ///
    /// exp138 read `0xfc078000` out of `get_partition_table_info(PT_INFO)` on a
    /// board with no partition table at all, and could only print it. This is
    /// what it says, and the test exists so that the meaning is attached to
    /// the capture rather than to a paragraph.
    #[test]
    fn the_word_exp138_read_off_a_stock_board() {
        let observed = 0xfc07_8000_u32;
        assert_eq!(observed & permission::ALL, permission::ALL, "all six permissions");
        assert_eq!(
            observed & !permission::ALL,
            family::ROM_DEFAULTS,
            "and exactly the four families the ROM defaults to"
        );
        // Which means it can be reused rather than invented: the first table
        // this repository writes agrees with the ROM's own default.
        assert_eq!(permission::ALL | family::ROM_DEFAULTS, observed);
    }

    #[test]
    fn a_partition_covering_the_rest_of_a_pico_2() {
        // Sector 0 holds the table, so the partition starts at 1. A Pico 2 has
        // 4 MiB fitted: 1024 sectors, numbered 0..=1023.
        let p = Partition::new(1, 1023, permission::ALL, family::RP2350_ARM_S);
        assert_eq!(p.sectors(), (1, 1023));
        assert_eq!(p.bytes(), (4096, 4 * 1024 * 1024 - 1));
        assert_eq!(p.location, 0xfc7f_e001);
        assert_eq!(p.flags, 0xfc02_0000);
    }

    /// A partition that contains the sector its own table lives in.
    ///
    /// Well-formed, and a trap: writing to it can erase the table that
    /// describes it. Asserted here so the shape is on the record, not because
    /// the crate prevents it — it cannot know which sector the table is in.
    #[test]
    fn a_partition_can_be_made_to_contain_its_own_table() {
        let p = Partition::new(0, 1023, permission::ALL, family::RP2350_ARM_S);
        assert_eq!(p.sectors().0, 0);
    }

    #[test]
    fn the_block_is_eight_words_and_ends_where_it_says() {
        let table = one_partition(
            permission::ALL | family::ROM_DEFAULTS,
            Partition::new(1, 1023, permission::ALL, family::RP2350_ARM_S),
        );
        assert_eq!(table[0], MARKER_START);
        assert_eq!(table[7], MARKER_END);
        assert_eq!(table[6], 0, "a one-block loop links to itself");
        assert_eq!(table[1] >> 24, 1, "one partition");
        assert_eq!(table[1] & 0xff, ITEM_PARTITION_TABLE as u32);
        assert_eq!(table[5] & 0xff, ITEM_LAST as u32);
    }

    /// The exact words exp139 places at flash offset 0.
    ///
    /// This is the test that matters. A table is eight numbers typed into a
    /// source file, and a wrong one produces a board that does not boot and
    /// says nothing about why. Pinning them here means a change has to be
    /// deliberate.
    #[test]
    fn exp139s_table_word_for_word() {
        let table = one_partition(
            permission::ALL | family::ROM_DEFAULTS,
            Partition::new(1, 1023, permission::ALL, family::RP2350_ARM_S),
        );
        assert_eq!(
            table,
            [
                0xffff_ded3,
                0x0100_040a,
                0xfc07_8000,
                0xfc7f_e001,
                0xfc02_0000,
                0x0000_04ff,
                0x0000_0000,
                0xab12_3579,
            ]
        );
    }

    /// The alternative encoding, written down rather than left to be
    /// re-derived by somebody holding a board that will not boot.
    ///
    /// This is not a test of behaviour — nothing here can know which is right.
    /// It pins the number so that "try the other one" is one edit rather than
    /// an afternoon with a datasheet.
    #[test]
    fn the_alternative_word_if_the_size_field_is_one_byte() {
        // Same fields, moved: value in bits 16..31 instead of 24..31, length
        // in bits 8..15 instead of 8..23.
        let one_byte = ((1_u32) << 16) | ((4_u32) << 8) | ITEM_PARTITION_TABLE as u32;
        assert_eq!(one_byte, ONE_BYTE_SIZE_ALTERNATIVE);
        assert_ne!(one_byte, item(1, 4, ITEM_PARTITION_TABLE));
    }

    /// What a second source did confirm, so that the unconfirmed part is not
    /// mistaken for the whole.
    #[test]
    fn the_values_the_pico_sdk_agrees_with() {
        // picobin.h, quoted in the crate docs.
        assert_eq!(MARKER_START, 0xffff_ded3);
        assert_eq!(MARKER_END, 0xab12_3579);
        assert_eq!(permission::SECURE_READ, 0x0400_0000);
        assert_eq!(permission::SECURE_WRITE, 0x0800_0000);
        assert_eq!(permission::NON_SECURE_READ, 0x1000_0000);
        assert_eq!(permission::NON_SECURE_WRITE, 0x2000_0000);
        assert_eq!(permission::BOOT_READ, 0x4000_0000);
        assert_eq!(permission::BOOT_WRITE, 0x8000_0000);
        assert_eq!(family::RP2040, 0x0000_4000);
        assert_eq!(family::ABSOLUTE, 0x0000_8000);
        assert_eq!(family::DATA, 0x0001_0000);
        assert_eq!(family::RP2350_ARM_S, 0x0002_0000);
        assert_eq!(family::RP2350_RISCV, 0x0004_0000);
        assert_eq!(family::RP2350_ARM_NS, 0x0008_0000);
        // 0x80 | 0x7f, which is the one item id the SDK spells out as 2-byte.
        assert_eq!(ITEM_LAST, 0xff);
    }

    #[test]
    fn item_encoding_is_value_length_id() {
        assert_eq!(item(1, 4, ITEM_PARTITION_TABLE), 0x0100_040a);
        assert_eq!(item(0, 4, ITEM_LAST), 0x0000_04ff);
    }
}
