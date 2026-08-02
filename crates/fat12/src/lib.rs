//! A FAT12 volume, written by hand into a slice.
//!
//! Nothing here is a filesystem *driver*. It lays out the bytes a filesystem
//! consists of, once, at boot — which is the whole claim: a filesystem is an
//! arrangement of bytes that other software has agreed to interpret, and you
//! can write one with an array and some arithmetic.
//!
//! # The layout, and why every number depends on the others
//!
//! ```text
//!   sector 0        boot sector, carrying the BPB that describes all of this
//!   sector 1        the FAT: 12-bit entries, 341 of them in 512 bytes
//!   sector 2        root directory: 16 entries of 32 bytes = exactly 512
//!   sector 3..128   data, one cluster per sector, 125 of them
//! ```
//!
//! These are not independent choices. `RESERVED + FATS * SECTORS_PER_FAT +
//! ROOT_SECTORS` is where the data area starts, the cluster count follows from
//! what is left, and **the cluster count is what decides whether this is
//! FAT12 at all** — under 4085 clusters means FAT12, and a host works that out
//! by doing this arithmetic rather than by reading the `"FAT12   "` string,
//! which is documentation for humans.
//!
//! Get one field wrong and the failure is rarely a refusal. It is a volume
//! that mounts and is wrong.

#![cfg_attr(not(test), no_std)]

/// Everything assumes 512, including the host.
pub const SECTOR: usize = 512;

const SECTORS_PER_CLUSTER: u8 = 1;
const RESERVED_SECTORS: u16 = 1;
const FAT_COUNT: u8 = 1;
const SECTORS_PER_FAT: u16 = 1;
const ROOT_ENTRIES: u16 = 16;

/// 32 bytes per directory entry, so sixteen entries is exactly one sector.
const ROOT_SECTORS: usize = (ROOT_ENTRIES as usize * 32) / SECTOR;

/// Where the data area begins, in sectors. Cluster 2 — the first cluster there
/// is — lives here, because clusters 0 and 1 do not exist and their FAT
/// entries are used for something else.
const DATA_START: usize =
    RESERVED_SECTORS as usize + FAT_COUNT as usize * SECTORS_PER_FAT as usize + ROOT_SECTORS;

/// `0xF8` is "fixed disk", `0xF0` is "removable". Either works; the value has
/// to appear twice — here and as the low byte of FAT entry 0 — and a host that
/// finds them disagreeing has grounds to distrust the whole volume.
const MEDIA_DESCRIPTOR: u8 = 0xF8;

/// FAT12 keeps a file's first cluster in the directory entry; the FAT holds
/// the rest of the chain. `0xFFF` means "this is the last one".
const FAT12_END_OF_CHAIN: u16 = 0xFFF;

/// The first cluster that can hold anything.
const FIRST_CLUSTER: u16 = 2;

/// Writes a 16-bit little-endian field. FAT is little-endian throughout —
/// unlike the SCSI it arrives over, which is not.
fn put_u16(buf: &mut [u8], at: usize, v: u16) {
    buf[at..at + 2].copy_from_slice(&v.to_le_bytes());
}

fn put_u32(buf: &mut [u8], at: usize, v: u32) {
    buf[at..at + 4].copy_from_slice(&v.to_le_bytes());
}

/// Packs one 12-bit FAT entry. Two entries share three bytes, which is the
/// entire reason FAT12 is fiddly and the reason it was worth doing by hand.
fn set_fat12(fat: &mut [u8], cluster: usize, value: u16) {
    let at = cluster * 3 / 2;
    if cluster % 2 == 0 {
        fat[at] = (value & 0xFF) as u8;
        fat[at + 1] = (fat[at + 1] & 0xF0) | ((value >> 8) & 0x0F) as u8;
    } else {
        fat[at] = (fat[at] & 0x0F) | ((value & 0x0F) << 4) as u8;
        fat[at + 1] = ((value >> 4) & 0xFF) as u8;
    }
}

/// A date in FAT's packed form: year since 1980 in the top seven bits, then
/// month, then day.
const fn fat_date(year: u16, month: u16, day: u16) -> u16 {
    ((year - 1980) << 9) | (month << 5) | day
}

/// Hours, minutes, and seconds in units of two — which is why a FAT timestamp
/// cannot represent an odd second.
const fn fat_time(hour: u16, minute: u16, second: u16) -> u16 {
    (hour << 11) | (minute << 5) | (second / 2)
}

const STAMP_DATE: u16 = fat_date(2026, 8, 2);
const STAMP_TIME: u16 = fat_time(12, 0, 0);

/// Writes one 32-byte directory entry.
fn dir_entry(buf: &mut [u8], name_8_3: &[u8; 11], attr: u8, cluster: u16, size: u32) {
    buf[..32].fill(0);
    buf[0..11].copy_from_slice(name_8_3);
    buf[11] = attr;
    put_u16(buf, 14, STAMP_TIME); // created
    put_u16(buf, 16, STAMP_DATE);
    put_u16(buf, 18, STAMP_DATE); // last accessed
    put_u16(buf, 22, STAMP_TIME); // last written
    put_u16(buf, 24, STAMP_DATE);
    put_u16(buf, 26, cluster);
    put_u32(buf, 28, size);
}

/// Lays a whole FAT12 volume into `disk`, with one file in the root.
///
/// Returns the number of clusters the volume ended up with, because that
/// number is the one that decides the FAT type and is worth printing rather
/// than assuming.
pub fn format(disk: &mut [u8], filename: &[u8; 11], label: &[u8; 11], contents: &[u8]) -> u32 {
    let total_sectors = (disk.len() / SECTOR) as u16;
    let clusters = (total_sectors as usize - DATA_START) / SECTORS_PER_CLUSTER as usize;

    disk.fill(0);

    // ---- sector 0: the boot sector -----------------------------------------
    //
    // The first three bytes are a jump instruction. Nothing here will ever
    // execute them, and they are not optional: a host that finds something
    // else at offset zero is entitled to decide this is not a FAT volume.
    let boot = &mut disk[0..SECTOR];
    boot[0] = 0xEB;
    boot[1] = 0x3C;
    boot[2] = 0x90;
    boot[3..11].copy_from_slice(b"MSWIN4.1"); // OEM name; widely-accepted filler
    put_u16(boot, 11, SECTOR as u16);
    boot[13] = SECTORS_PER_CLUSTER;
    put_u16(boot, 14, RESERVED_SECTORS);
    boot[16] = FAT_COUNT;
    put_u16(boot, 17, ROOT_ENTRIES);
    put_u16(boot, 19, total_sectors); // 16-bit count; the 32-bit field stays 0
    boot[21] = MEDIA_DESCRIPTOR;
    put_u16(boot, 22, SECTORS_PER_FAT);
    put_u16(boot, 24, 1); // sectors per track — geometry nothing here has
    put_u16(boot, 26, 1); // heads, likewise
    put_u32(boot, 28, 0); // hidden sectors: none, this is not in a partition
    put_u32(boot, 32, 0);
    boot[36] = 0x80; // drive number
    boot[38] = 0x29; // extended boot signature: the next three fields are real
    put_u32(boot, 39, 0x2635_1225); // volume serial
    boot[43..54].copy_from_slice(label);
    boot[54..62].copy_from_slice(b"FAT12   ");
    // The signature every host looks for first, and the reason a sector of
    // zeros is not an empty filesystem but no filesystem at all.
    boot[510] = 0x55;
    boot[511] = 0xAA;

    // ---- sector 1: the FAT --------------------------------------------------
    //
    // Entry 0 carries the media descriptor again with its top bits set; entry
    // 1 is an end-of-chain marker that means nothing. Neither describes a
    // cluster: clusters are numbered from 2, and those two slots are the price.
    let fat_start = RESERVED_SECTORS as usize * SECTOR;
    let fat = &mut disk[fat_start..fat_start + SECTOR];
    set_fat12(fat, 0, 0x0F00 | MEDIA_DESCRIPTOR as u16);
    set_fat12(fat, 1, FAT12_END_OF_CHAIN);
    set_fat12(fat, FIRST_CLUSTER as usize, FAT12_END_OF_CHAIN);

    // ---- sector 2: the root directory --------------------------------------
    //
    // The volume label is a directory entry with a bit set, not a property of
    // the volume — which is why the label in the boot sector above is ignored
    // by most software and this one is not.
    let root_start = fat_start + FAT_COUNT as usize * SECTORS_PER_FAT as usize * SECTOR;
    dir_entry(&mut disk[root_start..], label, 0x08, 0, 0);
    dir_entry(
        &mut disk[root_start + 32..],
        filename,
        0x20, // archive
        FIRST_CLUSTER,
        contents.len() as u32,
    );

    // ---- sector 3 onwards: the file ----------------------------------------
    let data_start = DATA_START * SECTOR;
    disk[data_start..data_start + contents.len()].copy_from_slice(contents);

    clusters as u32
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The three bytes two 12-bit entries share, checked against the values
    /// every FAT12 volume in the world begins with.
    #[test]
    fn twelve_bit_entries_pack_into_three_bytes() {
        let mut fat = [0u8; 8];
        set_fat12(&mut fat, 0, 0x0FF8);
        set_fat12(&mut fat, 1, 0x0FFF);
        assert_eq!(&fat[0..3], &[0xF8, 0xFF, 0xFF]);

        set_fat12(&mut fat, 2, 0x0FFF);
        assert_eq!(&fat[3..5], &[0xFF, 0x0F]);
    }

    #[test]
    fn odd_and_even_entries_do_not_overwrite_each_other() {
        let mut fat = [0u8; 8];
        set_fat12(&mut fat, 2, 0x123);
        set_fat12(&mut fat, 3, 0x456);
        assert_eq!(read_fat12(&fat, 2), 0x123);
        assert_eq!(read_fat12(&fat, 3), 0x456);
    }

    fn read_fat12(fat: &[u8], cluster: usize) -> u16 {
        let at = cluster * 3 / 2;
        let pair = u16::from_le_bytes([fat[at], fat[at + 1]]);
        if cluster % 2 == 0 {
            pair & 0x0FFF
        } else {
            pair >> 4
        }
    }

    #[test]
    fn the_layout_leaves_a_fat12_number_of_clusters() {
        // Under 4085 is what makes a host call this FAT12. The arithmetic that
        // decides it lives in `format`, so it is checked here rather than
        // trusted.
        let mut disk = [0u8; 128 * SECTOR];
        let clusters = format(&mut disk, b"README  TXT", b"YI26 EXP125", b"hello");
        assert_eq!(clusters, 125);
        assert!(clusters < 4085, "this layout would not be FAT12");
        assert_eq!(&disk[510..512], &[0x55, 0xAA]);
        assert_eq!(&disk[SECTOR..SECTOR + 3], &[0xF8, 0xFF, 0xFF]);
    }
}
