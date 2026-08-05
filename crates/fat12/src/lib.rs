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

/// One file to put in the root directory.
///
/// The name is the raw 8.3 field: eight bytes then three, space padded, no
/// dot. `b"INDEX   HTM"` is what a host shows as `INDEX.HTM` — the dot is
/// punctuation the listing adds, not a byte on the disk.
pub struct File<'a> {
    pub name: &'a [u8; 11],
    pub contents: &'a [u8],
}

/// What went wrong, when a layout cannot hold what it was asked to.
#[derive(Debug, PartialEq)]
pub enum FormatError {
    /// More files than the fixed-size root directory has slots. FAT12's root
    /// is not a file and cannot grow; the count is in the boot sector.
    TooManyFiles,
    /// The files need more clusters than the data area contains.
    OutOfSpace { needed: u32, available: u32 },
}

/// How many sectors a FAT12 volume's bookkeeping occupies, whatever size the
/// volume claims to be: the boot sector, one FAT, and the root directory.
///
/// Three. That is the whole filesystem, for a volume of any size this crate can
/// describe — a device that only wants to *receive* a file never has to store
/// the rest. [exp145](../../../experiments/exp145-a-drive-of-our-own/) serves a
/// volume out of exactly this many sectors and throws every data sector away
/// after reading what it wanted from it.
pub const METADATA_SECTORS: usize = DATA_START;

/// [`METADATA_SECTORS`] in bytes — the size of the buffer
/// [`format_metadata`] fills.
pub const METADATA_BYTES: usize = METADATA_SECTORS * SECTOR;

/// Lays out the bookkeeping for an **empty** volume of `total_sectors`, without
/// needing a buffer that size.
///
/// [`format`] needs the whole volume in memory because it places file contents
/// into the data area. A device that serves an empty volume for a host to write
/// *into* does not: the boot sector, the FAT and the root directory are three
/// sectors, and everything past them can be answered with zeros or dropped on
/// the floor.
///
/// Returns the cluster count the volume works out to, which is the number that
/// decides the FAT type. `SECTORS_PER_FAT` is one here, so a FAT12 table of 512
/// bytes runs out at about 341 clusters — declare more sectors than that and
/// the volume describes clusters the FAT cannot address.
pub fn format_metadata(meta: &mut [u8; METADATA_BYTES], total_sectors: u16, label: &[u8; 11]) -> u32 {
    write_metadata(meta, total_sectors, label);
    (total_sectors as usize - DATA_START) as u32
}

/// The boot sector, the FAT's first two slots, and the root directory's volume
/// label — the part of a layout that does not depend on what is stored in it.
fn write_metadata(disk: &mut [u8], total_sectors: u16, label: &[u8; 11]) {
    disk[..METADATA_BYTES].fill(0);

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

    // ---- the FAT's first two slots ------------------------------------------
    //
    // Entry 0 carries the media descriptor again with its top bits set; entry
    // 1 is an end-of-chain marker that means nothing. Neither describes a
    // cluster: clusters are numbered from 2, and those two slots are the price.
    let fat_start = RESERVED_SECTORS as usize * SECTOR;
    {
        let fat = &mut disk[fat_start..fat_start + SECTOR];
        set_fat12(fat, 0, 0x0F00 | MEDIA_DESCRIPTOR as u16);
        set_fat12(fat, 1, FAT12_END_OF_CHAIN);
    }

    // ---- sector 2: the root directory --------------------------------------
    //
    // The volume label is a directory entry with a bit set, not a property of
    // the volume — which is why the label in the boot sector above is ignored
    // by most software and this one is not.
    let root_start = fat_start + FAT_COUNT as usize * SECTORS_PER_FAT as usize * SECTOR;
    dir_entry(&mut disk[root_start..], label, 0x08, 0, 0);
}

/// Lays a whole FAT12 volume into `disk`, with `files` in the root.
///
/// Returns the number of clusters the volume ended up with, because that
/// number is the one that decides the FAT type and is worth printing rather
/// than assuming.
///
/// Files are allocated consecutively from cluster 2 and chained through the
/// FAT. A file longer than one cluster is the reason the table exists: the
/// directory entry holds only the *first* cluster, and each FAT slot says
/// which cluster follows, ending with [`FAT12_END_OF_CHAIN`].
pub fn format(disk: &mut [u8], label: &[u8; 11], files: &[File]) -> Result<u32, FormatError> {
    let total_sectors = (disk.len() / SECTOR) as u16;
    let clusters = ((total_sectors as usize - DATA_START) / SECTORS_PER_CLUSTER as usize) as u32;
    let bytes_per_cluster = SECTORS_PER_CLUSTER as usize * SECTOR;

    // The volume label takes a root slot of its own, which is easy to forget
    // because it does not look like a file.
    if files.len() + 1 > ROOT_ENTRIES as usize {
        return Err(FormatError::TooManyFiles);
    }

    let needed: u32 = files
        .iter()
        .map(|f| f.contents.len().div_ceil(bytes_per_cluster) as u32)
        .sum();
    if needed > clusters {
        return Err(FormatError::OutOfSpace { needed, available: clusters });
    }

    disk.fill(0);

    // The boot sector, the FAT's first two slots and the volume label are the
    // same three sectors whatever the volume holds, so they are laid out in one
    // place — the one a device that only receives files uses on its own.
    write_metadata(disk, total_sectors, label);

    let fat_start = RESERVED_SECTORS as usize * SECTOR;
    let root_start = fat_start + FAT_COUNT as usize * SECTORS_PER_FAT as usize * SECTOR;
    let data_start = DATA_START * SECTOR;

    // ---- the files, and the chains that hold them together ------------------
    let mut next_cluster = FIRST_CLUSTER;
    for (i, file) in files.iter().enumerate() {
        let count = file.contents.len().div_ceil(bytes_per_cluster).max(1) as u16;
        let first = next_cluster;

        for n in 0..count {
            let cluster = first + n;
            let value = if n + 1 == count { FAT12_END_OF_CHAIN } else { cluster + 1 };
            let fat = &mut disk[fat_start..fat_start + SECTOR];
            set_fat12(fat, cluster as usize, value);

            let at = data_start + (cluster - FIRST_CLUSTER) as usize * bytes_per_cluster;
            let from = n as usize * bytes_per_cluster;
            let take = bytes_per_cluster.min(file.contents.len().saturating_sub(from));
            disk[at..at + take].copy_from_slice(&file.contents[from..from + take]);
        }

        dir_entry(
            &mut disk[root_start + 32 * (i + 1)..],
            file.name,
            0x20, // archive
            first,
            file.contents.len() as u32,
        );
        next_cluster += count;
    }

    Ok(clusters)
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
        let clusters =
            format(&mut disk, b"YI26 EXP125", &[File { name: b"README  TXT", contents: b"hello" }])
                .unwrap();
        assert_eq!(clusters, 125);
        assert!(clusters < 4085, "this layout would not be FAT12");
        assert_eq!(&disk[510..512], &[0x55, 0xAA]);
        assert_eq!(&disk[SECTOR..SECTOR + 3], &[0xF8, 0xFF, 0xFF]);
    }

    /// The reason the table exists.
    ///
    /// A directory entry holds only the *first* cluster. Everything after it
    /// is found by following the chain, and a file that fits in one cluster
    /// never exercises that — which is why exp125 could be wrong about it and
    /// still mount.
    #[test]
    fn a_file_longer_than_one_cluster_is_chained_through_the_fat() {
        let mut disk = [0u8; 128 * SECTOR];
        let contents = [0x41u8; SECTOR * 3 + 1]; // three clusters and one byte
        format(&mut disk, b"YI26 EXP126", &[File { name: b"BIG     BIN", contents: &contents }])
            .unwrap();

        let fat = &disk[SECTOR..SECTOR * 2];
        assert_eq!(read_fat12(fat, 2), 3, "cluster 2 should point at 3");
        assert_eq!(read_fat12(fat, 3), 4);
        assert_eq!(read_fat12(fat, 4), 5);
        assert_eq!(read_fat12(fat, 5), 0xFFF, "the fourth cluster ends the chain");

        // And the bytes really are spread across those clusters.
        let data = DATA_START * SECTOR;
        assert_eq!(disk[data], 0x41);
        assert_eq!(disk[data + SECTOR * 3], 0x41, "the last cluster holds the last byte");
        assert_eq!(disk[data + SECTOR * 3 + 1], 0x00, "and nothing beyond it");
    }

    #[test]
    fn two_files_get_separate_chains() {
        let mut disk = [0u8; 128 * SECTOR];
        let a = [0x11u8; SECTOR * 2];
        format(
            &mut disk,
            b"YI26 EXP126",
            &[
                File { name: b"A       BIN", contents: &a },
                File { name: b"B       BIN", contents: b"second" },
            ],
        )
        .unwrap();

        let fat = &disk[SECTOR..SECTOR * 2];
        assert_eq!(read_fat12(fat, 2), 3);
        assert_eq!(read_fat12(fat, 3), 0xFFF, "the first file ends here");
        assert_eq!(read_fat12(fat, 4), 0xFFF, "and the second starts on its own cluster");
    }

    /// Refusing is the only honest answer, and the alternative is a volume
    /// whose directory points past the end of its own data area.
    #[test]
    fn a_file_too_big_for_the_volume_is_refused() {
        let mut disk = [0u8; 128 * SECTOR];
        let huge = [0u8; 200 * SECTOR];
        let err = format(&mut disk, b"YI26 EXP126", &[File { name: b"HUGE    BIN", contents: &huge }])
            .unwrap_err();
        assert_eq!(err, FormatError::OutOfSpace { needed: 200, available: 125 });
    }

    /// The claim `format_metadata` rests on: for an empty volume, the first
    /// three sectors it writes are byte-for-byte what `format` writes for a
    /// volume of the same declared size. A device can serve those three and
    /// keep none of the rest.
    #[test]
    fn metadata_only_matches_the_first_three_sectors_of_a_full_format() {
        const SECTORS: u16 = 256;
        let mut whole = [0u8; SECTORS as usize * SECTOR];
        format(&mut whole, b"DROP A UF2 ", &[]).unwrap();

        let mut meta = [0u8; METADATA_BYTES];
        let clusters = format_metadata(&mut meta, SECTORS, b"DROP A UF2 ");

        assert_eq!(&meta[..], &whole[..METADATA_BYTES], "boot sector, FAT and root");
        assert_eq!(clusters, SECTORS as u32 - 3, "clusters, minus the three it takes to say so");
        assert_eq!(METADATA_SECTORS, 3, "a whole FAT12 filesystem, in three sectors");
    }

    /// A volume big enough to matter still has a three-sector filesystem — the
    /// point of serving it this way. It also has more clusters than one 512-byte
    /// FAT12 table can address, which is the limit to declare a size against.
    #[test]
    fn the_metadata_does_not_grow_with_the_volume() {
        let mut small = [0u8; METADATA_BYTES];
        let mut large = [0u8; METADATA_BYTES];
        assert_eq!(format_metadata(&mut small, 64, b"SMALL      "), 61);
        assert_eq!(format_metadata(&mut large, 320, b"LARGE      "), 317);
        // 512 bytes of FAT12 hold 341 entries, two of which are not clusters.
        assert!(317 < 341 - 2, "a volume whose FAT cannot address its own clusters is a lie");
        assert_eq!(small.len(), large.len());
    }

    #[test]
    fn more_files_than_root_slots_is_refused() {
        let mut disk = [0u8; 128 * SECTOR];
        let files: [File; 16] = core::array::from_fn(|_| File { name: b"X       BIN", contents: b"x" });
        assert_eq!(
            format(&mut disk, b"YI26 EXP126", &files).unwrap_err(),
            FormatError::TooManyFiles,
            "the root directory is a fixed 16 entries and the label takes one"
        );
    }
}
