//! Assemble a partition table and an ordinary image into one partitioned image.
//!
//! exp139 learned, on hardware, that a partition image must be linked at the
//! XIP base `0x10000000` like any other — the ROM remaps a booted partition's
//! start to that address, so an image linked for its physical offset runs
//! `0x1000` off and faults. See
//! [`experiments/exp139-a-table-of-one`](../../experiments/exp139-a-table-of-one/).
//!
//! So the image is built normally, at `0x10000000`, and this tool does the one
//! thing that cannot be a link-time move: it places the table at flash offset 0
//! (physical sector 0) and the *unchanged* image one sector later (physical
//! sector 1), where the ROM's partition-0 remap puts it back at `0x10000000`.
//! The table and the image stay separate objects glued at the end — which is
//! how the platform keeps them — rather than one linked ELF.
//!
//! ```text
//!   in:  image.uf2      blocks at 0x10000000, 0x10000100, …  (linked at XIP base)
//!   out: exp139.uf2     [table] at 0x10000000
//!                       [image] at 0x10001000, 0x10001100, … (each block + 0x1000)
//! ```
//!
//! `yi26 pflash` writes those absolute addresses raw, so table and image land
//! exactly where addressed; `REBOOT2` then boots the partition.

use std::process::ExitCode;

/// Flash XIP base. A partition image is linked here, and the table lives at the
/// physical start of flash, which is the same address until a partition remap.
const XIP_BASE: u32 = 0x1000_0000;

/// One 4 KiB sector: the table takes sector 0, so the image shifts up by this.
const SECTOR: u32 = 0x1000;

/// UF2 block magics and the family-id flag.
const UF2_MAGIC0: u32 = 0x0A32_4655;
const UF2_MAGIC1: u32 = 0x9E5D_5157;
const UF2_MAGIC_END: u32 = 0x0AB1_6F30;
const UF2_FLAG_FAMILY: u32 = 0x0000_2000;

/// The UF2 family every firmware in this repository is: `rp2350-arm-s`. Used for
/// the table block when the input carries none; the image blocks keep their own.
const FAMILY_RP2350_ARM_S: u32 = 0xe48b_ff59;

/// exp139's table: one partition over sectors 1..1023, the ROM's own default
/// families for the unpartitioned space. The eight words — and the tests that
/// pin them — live in the `partition-table` crate, so this stays the single
/// source of truth for what the table *is*.
fn exp139_table_bytes() -> Vec<u8> {
    let words = partition_table::one_partition(
        partition_table::permission::ALL | partition_table::family::ROM_DEFAULTS,
        partition_table::Partition::new(
            1,
            1023,
            partition_table::permission::ALL,
            partition_table::family::RP2350_ARM_S,
        ),
    );
    let mut bytes = Vec::with_capacity(words.len() * 4);
    for w in words {
        bytes.extend_from_slice(&w.to_le_bytes());
    }
    bytes
}

/// One UF2 block, reduced to the three fields that matter here.
#[derive(Debug)]
struct Block {
    addr: u32,
    data: Vec<u8>,
    family: u32,
}

/// Parse a UF2 into its blocks. Ignores anything that is not a UF2 block, the
/// same way the flasher does, so a stray trailing byte is not fatal.
fn read_uf2(uf2: &[u8]) -> Result<Vec<Block>, String> {
    let mut blocks = Vec::new();
    for chunk in uf2.chunks(512) {
        if chunk.len() < 512 {
            break;
        }
        if u32::from_le_bytes(chunk[0..4].try_into().unwrap()) != UF2_MAGIC0 {
            continue;
        }
        let addr = u32::from_le_bytes(chunk[12..16].try_into().unwrap());
        let len = u32::from_le_bytes(chunk[16..20].try_into().unwrap()) as usize;
        let family = u32::from_le_bytes(chunk[28..32].try_into().unwrap());
        blocks.push(Block {
            addr,
            data: chunk[32..32 + len.min(476)].to_vec(),
            family,
        });
    }
    if blocks.is_empty() {
        return Err("no UF2 blocks — is this a .uf2 file?".into());
    }
    Ok(blocks)
}

/// Serialise blocks back to UF2, renumbering `blockNo`/`numBlocks`.
fn write_uf2(blocks: &[Block]) -> Vec<u8> {
    let mut out = Vec::with_capacity(blocks.len() * 512);
    let n = blocks.len() as u32;
    for (i, b) in blocks.iter().enumerate() {
        let mut blk = [0u8; 512];
        blk[0..4].copy_from_slice(&UF2_MAGIC0.to_le_bytes());
        blk[4..8].copy_from_slice(&UF2_MAGIC1.to_le_bytes());
        blk[8..12].copy_from_slice(&UF2_FLAG_FAMILY.to_le_bytes());
        blk[12..16].copy_from_slice(&b.addr.to_le_bytes());
        blk[16..20].copy_from_slice(&(b.data.len() as u32).to_le_bytes());
        blk[20..24].copy_from_slice(&(i as u32).to_le_bytes());
        blk[24..28].copy_from_slice(&n.to_le_bytes());
        blk[28..32].copy_from_slice(&b.family.to_le_bytes());
        blk[32..32 + b.data.len()].copy_from_slice(&b.data);
        blk[508..512].copy_from_slice(&UF2_MAGIC_END.to_le_bytes());
        out.extend_from_slice(&blk);
    }
    out
}

/// The assembly itself: the table at flash offset 0, then every image block one
/// sector higher. Fails loudly if the image was not linked at the XIP base,
/// because that is the whole mistake exp139 exists to not repeat.
fn assemble(image: &[Block]) -> Result<Vec<Block>, String> {
    let lowest = image.iter().map(|b| b.addr).min().unwrap();
    if lowest != XIP_BASE {
        return Err(format!(
            "the image starts at {lowest:#010x}, not {XIP_BASE:#010x}. A partition \
             image must be linked at the XIP base — the ROM remaps the partition \
             there. Build it like an ordinary image (no memory.x origin move)."
        ));
    }
    let family = image[0].family;
    let mut out = Vec::with_capacity(image.len() + 1);
    out.push(Block {
        addr: XIP_BASE,
        data: exp139_table_bytes(),
        family: if family == 0 { FAMILY_RP2350_ARM_S } else { family },
    });
    for b in image {
        out.push(Block {
            addr: b.addr + SECTOR,
            data: b.data.clone(),
            family: b.family,
        });
    }
    Ok(out)
}

fn run(input: &str, output: &str) -> Result<String, String> {
    let uf2 = std::fs::read(input).map_err(|e| format!("cannot read {input}: {e}"))?;
    let image = read_uf2(&uf2)?;
    let assembled = assemble(&image)?;
    let bytes = write_uf2(&assembled);
    std::fs::write(output, &bytes).map_err(|e| format!("cannot write {output}: {e}"))?;
    Ok(format!(
        "assembled {output}: table at {:#010x} (sector 0), image at {:#010x} \
         (sector 1), {} blocks. pflash it, then REBOOT2 boots the partition.",
        XIP_BASE,
        XIP_BASE + SECTOR,
        assembled.len()
    ))
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: partimg <image.uf2> <out.uf2>");
        eprintln!("  <image.uf2>  an ordinary image, linked at 0x10000000");
        eprintln!("  <out.uf2>    the partitioned image: table at sector 0, image at sector 1");
        return ExitCode::from(2);
    }
    match run(&args[1], &args[2]) {
        Ok(msg) => {
            println!("{msg}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("partimg: {e}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a one-block UF2 for a fake image at a given base.
    fn fake_image_uf2(base: u32, payload: &[u8]) -> Vec<u8> {
        let block = Block {
            addr: base,
            data: payload.to_vec(),
            family: FAMILY_RP2350_ARM_S,
        };
        write_uf2(&[block])
    }

    #[test]
    fn table_is_the_crate_s_eight_words() {
        let bytes = exp139_table_bytes();
        assert_eq!(bytes.len(), 32, "eight words");
        // First word is the start marker, last is the end marker — least-
        // significant byte first.
        assert_eq!(&bytes[0..4], &0xffff_ded3u32.to_le_bytes());
        assert_eq!(&bytes[28..32], &0xab12_3579u32.to_le_bytes());
    }

    #[test]
    fn assemble_places_table_then_shifts_the_image() {
        let payload = [0xAAu8; 200];
        let uf2 = fake_image_uf2(XIP_BASE, &payload);
        let out = assemble(&read_uf2(&uf2).unwrap()).unwrap();

        assert_eq!(out.len(), 2, "one table block plus one image block");
        // Table lands at flash offset 0, and is exactly the crate's words.
        assert_eq!(out[0].addr, XIP_BASE);
        assert_eq!(out[0].data, exp139_table_bytes());
        // The image block moved up one sector, byte-for-byte unchanged.
        assert_eq!(out[1].addr, XIP_BASE + SECTOR);
        assert_eq!(out[1].data, payload);
    }

    #[test]
    fn round_trips_through_uf2_bytes() {
        let payload = [0x5Au8; 256];
        let uf2 = fake_image_uf2(XIP_BASE, &payload);
        let assembled = assemble(&read_uf2(&uf2).unwrap()).unwrap();
        // Serialise and parse back: the addresses and payloads survive.
        let reparsed = read_uf2(&write_uf2(&assembled)).unwrap();
        assert_eq!(reparsed.len(), 2);
        assert_eq!(reparsed[0].addr, XIP_BASE);
        assert_eq!(reparsed[0].data, exp139_table_bytes());
        assert_eq!(reparsed[1].addr, XIP_BASE + SECTOR);
        assert_eq!(reparsed[1].data, payload.to_vec());
        // Block numbering is rewritten to 0..N.
        let raw = write_uf2(&assembled);
        assert_eq!(u32::from_le_bytes(raw[20..24].try_into().unwrap()), 0);
        assert_eq!(u32::from_le_bytes(raw[24..28].try_into().unwrap()), 2);
    }

    #[test]
    fn refuses_an_image_not_linked_at_the_xip_base() {
        // The exact mistake exp139 made: image built at 0x10001000.
        let uf2 = fake_image_uf2(XIP_BASE + SECTOR, &[0u8; 16]);
        let err = assemble(&read_uf2(&uf2).unwrap()).unwrap_err();
        assert!(err.contains("must be linked at the XIP base"), "{err}");
    }
}
