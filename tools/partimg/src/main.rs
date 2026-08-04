//! Assemble a partition table and ordinary image(s) into one partitioned image.
//!
//! exp139 learned, on hardware, that a partition image must be linked at the
//! XIP base `0x10000000` like any other — the ROM remaps a booted partition's
//! start to that address, so an image linked for its physical offset runs
//! `0x1000` off and faults. So the images are built normally, at `0x10000000`,
//! and this tool does the one thing that cannot be a link-time move: it places
//! the table at flash offset 0 and each *unchanged* image at its partition's
//! start sector, where the ROM's remap puts it back at `0x10000000`.
//!
//! Two modes, for two experiments:
//!
//! ```text
//!   partimg one <image.uf2> <out.uf2>            exp139: one partition
//!       [table]        @ 0x10000000  (sector 0)
//!       [image]        @ 0x10001000  (sector 1)
//!
//!   partimg ab <a.uf2> <b.uf2> <out.uf2>         exp142: an A/B pair
//!       [A/B table]    @ 0x10000000  (sector 0)
//!       [image A]      @ 0x10001000  (sector 1)
//!       [image B]      @ 0x10200000  (sector 512)
//! ```
//!
//! `yi26 pflash` writes those absolute addresses raw, so table and images land
//! exactly where addressed; `REBOOT2` then boots the partition (for `ab`, the
//! one whose image carries the higher version).

use std::process::ExitCode;

/// Flash XIP base — where every image is linked and where the table lives.
const XIP_BASE: u32 = 0x1000_0000;

/// One 4 KiB sector.
const SECTOR: u32 = 0x1000;

/// exp142's A/B layout: A over sectors 1..16, B over 17..32 — small and
/// adjacent on purpose. Real A/B slots are half the flash each, but the image B
/// placement sector is also where `pflash` starts writing, and a slot at sector
/// 512 makes the assembled image span 2 MiB of mostly-`0xFF`, which a single
/// `FLASH_ERASE` will not take. A/B selection does not depend on slot size, so
/// the slots here are just big enough for the image. The table (from the
/// `partition-table` crate) declares exactly these bounds, so the placement here
/// and the table there are built from the same numbers.
const A_FIRST: u32 = 1;
const A_LAST: u32 = 16;
const B_FIRST: u32 = 17;
const B_LAST: u32 = 32;

const UF2_MAGIC0: u32 = 0x0A32_4655;
const UF2_MAGIC1: u32 = 0x9E5D_5157;
const UF2_MAGIC_END: u32 = 0x0AB1_6F30;
const UF2_FLAG_FAMILY: u32 = 0x0000_2000;
const FAMILY_RP2350_ARM_S: u32 = 0xe48b_ff59;

/// exp139's table: one partition over sectors 1..1023.
fn one_table_bytes() -> Vec<u8> {
    let words = partition_table::one_partition(
        partition_table::permission::ALL | partition_table::family::ROM_DEFAULTS,
        partition_table::Partition::new(
            1,
            1023,
            partition_table::permission::ALL,
            partition_table::family::RP2350_ARM_S,
        ),
    );
    words_to_bytes(&words)
}

/// exp142's A/B table: A over sectors 1..16, B over 17..32 linked to A.
fn ab_table_bytes() -> Vec<u8> {
    let a = partition_table::Partition::new(
        A_FIRST as u16,
        A_LAST as u16,
        partition_table::permission::ALL,
        partition_table::family::RP2350_ARM_S,
    );
    let b = partition_table::Partition::new(
        B_FIRST as u16,
        B_LAST as u16,
        partition_table::permission::ALL,
        partition_table::family::RP2350_ARM_S | partition_table::link::to_a(0),
    );
    let words = partition_table::two_partitions_ab(
        partition_table::permission::ALL | partition_table::family::ROM_DEFAULTS,
        a,
        b,
    );
    words_to_bytes(&words)
}

fn words_to_bytes(words: &[u32]) -> Vec<u8> {
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

/// Parse a UF2 into its blocks, ignoring anything that is not one.
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

/// One image and the sector its partition starts at.
struct Placement<'a> {
    image: &'a [Block],
    first_sector: u32,
}

/// Assemble: the table at flash offset 0, then each image shifted up to its
/// partition's start sector. Refuses any image not linked at the XIP base —
/// that is the mistake exp139 exists to not repeat.
fn assemble(table: Vec<u8>, placements: &[Placement]) -> Result<Vec<Block>, String> {
    let mut family = FAMILY_RP2350_ARM_S;
    for p in placements {
        let lowest = p.image.iter().map(|b| b.addr).min().unwrap();
        if lowest != XIP_BASE {
            return Err(format!(
                "an image starts at {lowest:#010x}, not {XIP_BASE:#010x}. A partition \
                 image must be linked at the XIP base — the ROM remaps the partition \
                 there. Build it like an ordinary image (no memory.x origin move)."
            ));
        }
        family = p.image[0].family;
    }
    let mut out = Vec::new();
    out.push(Block {
        addr: XIP_BASE,
        data: table,
        family: if family == 0 { FAMILY_RP2350_ARM_S } else { family },
    });
    for p in placements {
        let shift = p.first_sector * SECTOR;
        for b in p.image {
            out.push(Block {
                addr: b.addr + shift,
                data: b.data.clone(),
                family: b.family,
            });
        }
    }
    Ok(out)
}

fn write_out(output: &str, blocks: &[Block]) -> Result<(), String> {
    std::fs::write(output, write_uf2(blocks)).map_err(|e| format!("cannot write {output}: {e}"))
}

fn read_image(path: &str) -> Result<Vec<Block>, String> {
    let uf2 = std::fs::read(path).map_err(|e| format!("cannot read {path}: {e}"))?;
    read_uf2(&uf2)
}

fn run(args: &[String]) -> Result<String, String> {
    match args.first().map(String::as_str) {
        Some("one") if args.len() == 3 => {
            let image = read_image(&args[1])?;
            let out = assemble(
                one_table_bytes(),
                &[Placement {
                    image: &image,
                    first_sector: A_FIRST,
                }],
            )?;
            write_out(&args[2], &out)?;
            Ok(format!(
                "assembled {}: table at {:#010x} (sector 0), image at {:#010x} \
                 (sector {}), {} blocks.",
                args[2],
                XIP_BASE,
                XIP_BASE + A_FIRST * SECTOR,
                A_FIRST,
                out.len()
            ))
        }
        Some("ab") if args.len() == 4 => {
            let a = read_image(&args[1])?;
            let b = read_image(&args[2])?;
            let out = assemble(
                ab_table_bytes(),
                &[
                    Placement {
                        image: &a,
                        first_sector: A_FIRST,
                    },
                    Placement {
                        image: &b,
                        first_sector: B_FIRST,
                    },
                ],
            )?;
            write_out(&args[3], &out)?;
            Ok(format!(
                "assembled {}: A/B table at {:#010x}, image A at {:#010x} (sector {}), \
                 image B at {:#010x} (sector {}), {} blocks. The ROM boots whichever \
                 image's VERSION is higher.",
                args[3],
                XIP_BASE,
                XIP_BASE + A_FIRST * SECTOR,
                A_FIRST,
                XIP_BASE + B_FIRST * SECTOR,
                B_FIRST,
                out.len()
            ))
        }
        _ => Err("usage".into()),
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(msg) => {
            println!("{msg}");
            ExitCode::SUCCESS
        }
        Err(e) if e == "usage" => {
            eprintln!("usage: partimg one <image.uf2> <out.uf2>       # exp139: one partition");
            eprintln!("       partimg ab <a.uf2> <b.uf2> <out.uf2>    # exp142: an A/B pair");
            eprintln!("both take images linked at 0x10000000; the table and placement are added here.");
            ExitCode::from(2)
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

    fn fake_image_uf2(base: u32, payload: &[u8]) -> Vec<u8> {
        write_uf2(&[Block {
            addr: base,
            data: payload.to_vec(),
            family: FAMILY_RP2350_ARM_S,
        }])
    }

    #[test]
    fn one_places_table_then_shifts_the_image() {
        let payload = [0xAAu8; 200];
        let img = read_uf2(&fake_image_uf2(XIP_BASE, &payload)).unwrap();
        let out = assemble(
            one_table_bytes(),
            &[Placement {
                image: &img,
                first_sector: A_FIRST,
            }],
        )
        .unwrap();
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].addr, XIP_BASE);
        assert_eq!(out[0].data, one_table_bytes());
        assert_eq!(out[1].addr, XIP_BASE + SECTOR);
        assert_eq!(out[1].data, payload);
    }

    #[test]
    fn ab_places_table_then_both_images_at_their_sectors() {
        let pa = [0xA1u8; 100];
        let pb = [0xB2u8; 120];
        let a = read_uf2(&fake_image_uf2(XIP_BASE, &pa)).unwrap();
        let b = read_uf2(&fake_image_uf2(XIP_BASE, &pb)).unwrap();
        let out = assemble(
            ab_table_bytes(),
            &[
                Placement {
                    image: &a,
                    first_sector: A_FIRST,
                },
                Placement {
                    image: &b,
                    first_sector: B_FIRST,
                },
            ],
        )
        .unwrap();
        assert_eq!(out.len(), 3, "table + A + B");
        assert_eq!(out[0].addr, XIP_BASE);
        assert_eq!(out[0].data, ab_table_bytes());
        assert_eq!(out[1].addr, XIP_BASE + A_FIRST * SECTOR); // 0x10001000
        assert_eq!(out[1].data, pa);
        assert_eq!(out[2].addr, XIP_BASE + B_FIRST * SECTOR); // 0x10011000
        assert_eq!(out[2].data, pb);
    }

    #[test]
    fn refuses_an_image_not_linked_at_the_xip_base() {
        let bad = read_uf2(&fake_image_uf2(XIP_BASE + SECTOR, &[0u8; 16])).unwrap();
        let err = assemble(
            ab_table_bytes(),
            &[Placement {
                image: &bad,
                first_sector: A_FIRST,
            }],
        )
        .unwrap_err();
        assert!(err.contains("must be linked at the XIP base"), "{err}");
    }

    #[test]
    fn the_ab_table_has_two_partitions_and_a_link() {
        // The table partimg emits is the crate's, so this pins the wiring: two
        // partitions (count 2 in the header) and the B link bit set.
        let t = ab_table_bytes();
        let header = u32::from_le_bytes(t[4..8].try_into().unwrap());
        assert_eq!(header >> 24, 2, "two partitions");
        // B's flags word is the 7th u32 (index 6); the link-to-A bit is 0x2.
        let b_flags = u32::from_le_bytes(t[24..28].try_into().unwrap());
        assert_eq!(b_flags & 0x2, 0x2, "B links to A");
    }
}
