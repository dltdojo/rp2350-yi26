//! Driving the RP2350 bootrom's PICOBOOT interface to erase flash.
//!
//! This exists for one reason exp141 turned up the hard way: exp139's
//! partition table, written to flash offset 0, made the bootrom's *drag-and-
//! drop* flashing (the mass-storage drive) refuse ordinary UF2s — the board
//! looked bricked, and only BOOTSEL still worked. PICOBOOT is the other
//! interface BOOTSEL exposes, the one `picotool` drives, and its `FLASH_ERASE`
//! command writes flash directly rather than through the partition-aware UF2
//! path. So it erases the bad table and the board is a stock board again.
//!
//! The chip is in BOOTSEL (`2e8a:000f`), Interface 1 is Vendor `0xFF` with a
//! bulk pair (OUT `0x03`, IN `0x84`) — read off real silicon in exp141. None
//! of this touches the application-firmware device (`1209:0001`); a board
//! running firmware has no PICOBOOT interface at all.

use std::time::Duration;

use nusb::MaybeFuture;

const BOOTSEL_VID: u16 = 0x2e8a;
const BOOTSEL_PID: u16 = 0x000f;

/// First word of every command packet (`PICOBOOT_MAGIC`).
const MAGIC: u32 = 0x431f_d10b;

// Command IDs, from the Pico SDK's picoboot.h.
const CMD_EXCLUSIVE_ACCESS: u8 = 0x1;
const CMD_EXIT_XIP: u8 = 0x6;
const CMD_FLASH_ERASE: u8 = 0x3;
const CMD_WRITE: u8 = 0x5;
const CMD_REBOOT2: u8 = 0xa;
/// REBOOT2 dFlags: type NORMAL boots the flash image; NO_RETURN resets instead
/// of returning to the caller. From boot/picoboot_constants.h.
const REBOOT2_NORMAL: u32 = 0x0;
const REBOOT2_NO_RETURN: u32 = 0x100;

/// Flash XIP base — every PICOBOOT flash address is absolute from here.
const FLASH_BASE: u32 = 0x1000_0000;
/// Flash erase granularity (one sector).
const SECTOR: u32 = 4096;
/// How much to write per WRITE command. A sector at a time keeps each transfer
/// small and sector-aligned; the bootrom's buffer comfortably holds it.
const CHUNK: usize = 4096;

// Interface control requests.
const IF_RESET: u8 = 0x41;

const TIMEOUT: Duration = Duration::from_secs(3);

/// Build the 32-byte PICOBOOT command packet.
fn packet(token: u32, cmd_id: u8, args: &[u8], transfer_len: u32) -> [u8; 32] {
    let mut p = [0u8; 32];
    p[0..4].copy_from_slice(&MAGIC.to_le_bytes());
    p[4..8].copy_from_slice(&token.to_le_bytes());
    p[8] = cmd_id;
    p[9] = args.len() as u8; // bCmdSize
    // p[10..12] reserved, zero.
    p[12..16].copy_from_slice(&transfer_len.to_le_bytes());
    p[16..16 + args.len()].copy_from_slice(args);
    p
}

/// One no-data command: write the 32-byte packet, then read the bootrom's
/// acknowledgement transfer from IN. A command that is accepted answers with a
/// (typically zero-length) IN transfer; a failure stalls, which nusb surfaces
/// as an error.
fn run(
    writer: &mut nusb::Endpoint<nusb::transfer::Bulk, nusb::transfer::Out>,
    reader: &mut nusb::Endpoint<nusb::transfer::Bulk, nusb::transfer::In>,
    token: u32,
    name: &str,
    cmd: u8,
    args: &[u8],
) -> Result<(), String> {
    reader.submit(nusb::transfer::Buffer::new(64));
    let pkt = packet(token, cmd, args, 0);
    let sent = writer.transfer_blocking(nusb::transfer::Buffer::from(&pkt[..]), TIMEOUT);
    sent.status
        .map_err(|e| format!("{name}: command write failed: {e}"))?;
    let ack = reader
        .wait_next_complete(TIMEOUT)
        .ok_or_else(|| format!("{name}: no acknowledgement — the bootrom did not accept it"))?;
    ack.status
        .map_err(|e| format!("{name}: acknowledgement stalled: {e}"))?;
    Ok(())
}

/// A data-carrying command: 32-byte packet, then the payload on bulk OUT, then
/// the acknowledgement on bulk IN. This is `picoboot_cmd` with a non-NULL
/// buffer — used by WRITE.
fn run_with_data(
    writer: &mut nusb::Endpoint<nusb::transfer::Bulk, nusb::transfer::Out>,
    reader: &mut nusb::Endpoint<nusb::transfer::Bulk, nusb::transfer::In>,
    token: u32,
    cmd: u8,
    args: &[u8],
    data: &[u8],
) -> Result<(), String> {
    let pkt = packet(token, cmd, args, data.len() as u32);
    writer
        .transfer_blocking(nusb::transfer::Buffer::from(&pkt[..]), TIMEOUT)
        .status
        .map_err(|e| format!("WRITE: command packet failed: {e}"))?;
    writer
        .transfer_blocking(nusb::transfer::Buffer::from(data), TIMEOUT)
        .status
        .map_err(|e| format!("WRITE: data phase failed: {e}"))?;
    reader.submit(nusb::transfer::Buffer::new(64));
    reader
        .wait_next_complete(TIMEOUT)
        .ok_or("WRITE: no acknowledgement")?
        .status
        .map_err(|e| format!("WRITE: acknowledgement stalled: {e}"))?;
    Ok(())
}

/// PC_READ — an IN command (top bit set), so the acknowledgement is a
/// zero-length OUT after the data comes back on IN.
const CMD_READ: u8 = 0x84;

/// Read `len` bytes of flash from absolute `addr` over PICOBOOT.
fn read_flash(
    writer: &mut nusb::Endpoint<nusb::transfer::Bulk, nusb::transfer::Out>,
    reader: &mut nusb::Endpoint<nusb::transfer::Bulk, nusb::transfer::In>,
    token: u32,
    addr: u32,
    len: u32,
) -> Result<Vec<u8>, String> {
    let mut ra = [0u8; 8];
    ra[0..4].copy_from_slice(&addr.to_le_bytes());
    ra[4..8].copy_from_slice(&len.to_le_bytes());
    let pkt = packet(token, CMD_READ, &ra, len);
    reader.submit(nusb::transfer::Buffer::new(len as usize));
    writer
        .transfer_blocking(nusb::transfer::Buffer::from(&pkt[..]), TIMEOUT)
        .status
        .map_err(|e| format!("READ: command failed: {e}"))?;
    let got = reader
        .wait_next_complete(TIMEOUT)
        .ok_or("READ: no data came back")?;
    got.status.map_err(|e| format!("READ: transfer failed: {e}"))?;
    let data = got.buffer[..got.actual_len].to_vec();
    // Acknowledge: zero-length OUT, because this was an IN command.
    let _ = writer.transfer_blocking(nusb::transfer::Buffer::from(&[][..]), TIMEOUT);
    Ok(data)
}

/// Parse a UF2 into a single contiguous flash image and its base address.
///
/// Gaps between blocks are filled with `0xFF` (erased flash), so a firmware
/// whose blocks are not perfectly dense still lands correctly. The repository's
/// own firmwares are contiguous, but padding costs nothing and removes an
/// assumption.
fn uf2_to_image(uf2: &[u8]) -> Result<(u32, Vec<u8>), String> {
    let mut blocks: Vec<(u32, Vec<u8>)> = Vec::new();
    for chunk in uf2.chunks(512) {
        if chunk.len() < 512 {
            break;
        }
        let magic0 = u32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
        if magic0 != 0x0A32_4655 {
            continue;
        }
        let addr = u32::from_le_bytes([chunk[12], chunk[13], chunk[14], chunk[15]]);
        let len = u32::from_le_bytes([chunk[16], chunk[17], chunk[18], chunk[19]]) as usize;
        blocks.push((addr, chunk[32..32 + len.min(476)].to_vec()));
    }
    if blocks.is_empty() {
        return Err("no UF2 blocks — is this a .uf2 file?".into());
    }
    let base = blocks.iter().map(|(a, _)| *a).min().unwrap();
    let end = blocks.iter().map(|(a, d)| *a + d.len() as u32).max().unwrap();
    let mut image = vec![0xFFu8; (end - base) as usize];
    for (addr, data) in &blocks {
        let off = (*addr - base) as usize;
        image[off..off + data.len()].copy_from_slice(data);
    }
    Ok((base, image))
}

/// Flash a UF2 over PICOBOOT — erase, write, reboot — with no mass-storage
/// drive anywhere in it.
///
/// This is the reliable path the drag-and-drop drive is not: the bootrom writes
/// exactly the bytes handed to it, with no host storage cache in between. It is
/// what makes flashing from a phone (or an automated harness) dependable.
pub fn flash_uf2(uf2_path: &std::path::Path) -> Result<String, String> {
    let uf2 = std::fs::read(uf2_path).map_err(|e| format!("cannot read UF2: {e}"))?;
    let (base, image) = uf2_to_image(&uf2)?;
    let erase_len = (image.len() as u32).div_ceil(SECTOR) * SECTOR;

    let (dev, iface, iface_num) = open_picoboot()?;
    let (mut writer, mut reader) = picoboot_endpoints(&iface)?;
    if_reset(&iface, iface_num)?;

    run(&mut writer, &mut reader, 1, "EXCLUSIVE_ACCESS", CMD_EXCLUSIVE_ACCESS, &[1])?;
    run(&mut writer, &mut reader, 2, "EXIT_XIP", CMD_EXIT_XIP, &[])?;

    // Erase the whole target range first, sector-aligned.
    let mut ea = [0u8; 8];
    ea[0..4].copy_from_slice(&base.to_le_bytes());
    ea[4..8].copy_from_slice(&erase_len.to_le_bytes());
    run(&mut writer, &mut reader, 3, "FLASH_ERASE", CMD_FLASH_ERASE, &ea)?;

    // Write in sector-sized chunks. The last chunk is padded to a page with
    // 0xFF so the length stays flash-aligned.
    let mut token = 4u32;
    let mut off = 0usize;
    while off < image.len() {
        let mut chunk = image[off..(off + CHUNK).min(image.len())].to_vec();
        while chunk.len() % 256 != 0 {
            chunk.push(0xFF);
        }
        let addr = base + off as u32;
        let mut wa = [0u8; 8];
        wa[0..4].copy_from_slice(&addr.to_le_bytes());
        wa[4..8].copy_from_slice(&(chunk.len() as u32).to_le_bytes());
        run_with_data(&mut writer, &mut reader, token, CMD_WRITE, &wa, &chunk)?;
        token += 1;
        off += CHUNK;
    }

    // Read the first sector back and compare, so a WRITE that did not take is
    // caught here rather than as a board that mysteriously will not boot.
    let check_len = image.len().min(256) as u32;
    let back = read_flash(&mut writer, &mut reader, token, base, check_len)?;
    token += 1;
    if back.len() < check_len as usize || back[..] != image[..check_len as usize] {
        return Err(format!(
            "WRITE did not verify: flash at {base:#010x} does not match the image. \
             first bytes on flash: {:02x?}",
            &back[..back.len().min(16)]
        ));
    }

    // Reboot into the image just written, with REBOOT2 (the RP2350 command),
    // type NORMAL. The RP2040-style REBOOT (pc/sp) lands in BOOTSEL on this
    // chip even with a valid image — confirmed the hard way — because pc=0/sp=0
    // is not "boot flash" here. REBOOT2 dFlags = NORMAL (0x0) | NO_RETURN
    // (0x100) resets and boots the flash image. args = dFlags, dDelayMS,
    // dParam0, dParam1.
    let mut rb = [0u8; 16];
    rb[0..4].copy_from_slice(&(REBOOT2_NORMAL | REBOOT2_NO_RETURN).to_le_bytes());
    rb[4..8].copy_from_slice(&100u32.to_le_bytes()); // dDelayMS
    reader.submit(nusb::transfer::Buffer::new(64));
    let pkt = packet(token, CMD_REBOOT2, &rb, 0);
    let _ = writer.transfer_blocking(nusb::transfer::Buffer::from(&pkt[..]), TIMEOUT);
    let _ = reader.wait_next_complete(Duration::from_millis(500));
    drop(dev);

    Ok(format!(
        "flashed {} bytes to {:#010x} over PICOBOOT ({} sectors erased), and \
         rebooted into it. No drive, no drag-and-drop.",
        image.len(),
        base,
        erase_len / SECTOR
    ))
}

/// Open the BOOTSEL device and claim its PICOBOOT interface.
fn open_picoboot() -> Result<(nusb::Device, nusb::Interface, u8), String> {
    let info = nusb::list_devices()
        .wait()
        .map_err(|e| format!("cannot enumerate USB: {e}"))?
        .find(|d| d.vendor_id() == BOOTSEL_VID && d.product_id() == BOOTSEL_PID)
        .ok_or("no board in BOOTSEL — `yi26 bootsel` first, or hold the button")?;
    let iface_num = info
        .interfaces()
        .find(|i| i.class() == 0xFF)
        .map(|i| i.interface_number())
        .ok_or("the BOOTSEL device has no PICOBOOT interface")?;
    let dev = info
        .open()
        .wait()
        .map_err(|e| format!("cannot open BOOTSEL device: {e} — udev rule for 2e8a:000f?"))?;
    let iface = dev
        .claim_interface(iface_num)
        .wait()
        .map_err(|e| format!("cannot claim PICOBOOT interface {iface_num}: {e}"))?;
    Ok((dev, iface, iface_num))
}

type BulkPair = (
    nusb::Endpoint<nusb::transfer::Bulk, nusb::transfer::Out>,
    nusb::Endpoint<nusb::transfer::Bulk, nusb::transfer::In>,
);

fn picoboot_endpoints(iface: &nusb::Interface) -> Result<BulkPair, String> {
    let (mut ep_out, mut ep_in) = (None, None);
    for ep in iface.descriptors().next().ok_or("no alternate setting")?.endpoints() {
        if ep.transfer_type() != nusb::descriptors::TransferType::Bulk {
            continue;
        }
        match ep.direction() {
            nusb::transfer::Direction::Out if ep_out.is_none() => ep_out = Some(ep.address()),
            nusb::transfer::Direction::In if ep_in.is_none() => ep_in = Some(ep.address()),
            _ => {}
        }
    }
    let writer = iface
        .endpoint::<nusb::transfer::Bulk, nusb::transfer::Out>(ep_out.ok_or("no bulk OUT")?)
        .map_err(|e| format!("cannot open bulk OUT: {e}"))?;
    let reader = iface
        .endpoint::<nusb::transfer::Bulk, nusb::transfer::In>(ep_in.ok_or("no bulk IN")?)
        .map_err(|e| format!("cannot open bulk IN: {e}"))?;
    Ok((writer, reader))
}

fn if_reset(iface: &nusb::Interface, iface_num: u8) -> Result<(), String> {
    iface
        .control_out(
            nusb::transfer::ControlOut {
                control_type: nusb::transfer::ControlType::Vendor,
                recipient: nusb::transfer::Recipient::Interface,
                request: IF_RESET,
                value: 0,
                index: iface_num as u16,
                data: &[],
            },
            TIMEOUT,
        )
        .wait()
        .map_err(|e| format!("IF_RESET failed: {e}"))?;
    Ok(())
}

/// Erase `size` bytes of flash from offset 0, over PICOBOOT.
///
/// 64 KiB by default at the call site: the partition table lives in the first
/// 4 KiB sector, and erasing a little more clears any image-definition block
/// that followed it, so the board comes up as unambiguously blank.
pub fn erase_flash(size: u32) -> Result<String, String> {
    let info = nusb::list_devices()
        .wait()
        .map_err(|e| format!("cannot enumerate USB: {e}"))?
        .find(|d| d.vendor_id() == BOOTSEL_VID && d.product_id() == BOOTSEL_PID)
        .ok_or(
            "no board in BOOTSEL. This drives the bootrom, not a running firmware — \
             put the board into BOOTSEL first (`yi26 bootsel`, or hold the button).",
        )?;

    // Find PICOBOOT by class, as exp132/exp141 do: it is the 0xFF interface.
    let mut iface_num = None;
    for i in info.interfaces() {
        if i.class() == 0xFF {
            iface_num = Some(i.interface_number());
            break;
        }
    }
    let iface_num =
        iface_num.ok_or("the BOOTSEL device has no vendor (PICOBOOT) interface")?;

    let dev = info
        .open()
        .wait()
        .map_err(|e| format!("cannot open the BOOTSEL device: {e} — udev rule for 2e8a:000f?"))?;
    let iface = dev
        .claim_interface(iface_num)
        .wait()
        .map_err(|e| format!("cannot claim PICOBOOT interface {iface_num}: {e}"))?;

    // Bulk endpoints, walked from the descriptors rather than assumed.
    let (mut ep_out, mut ep_in) = (None, None);
    for ep in iface
        .descriptors()
        .next()
        .ok_or("no alternate setting")?
        .endpoints()
    {
        if ep.transfer_type() != nusb::descriptors::TransferType::Bulk {
            continue;
        }
        match ep.direction() {
            nusb::transfer::Direction::Out if ep_out.is_none() => ep_out = Some(ep.address()),
            nusb::transfer::Direction::In if ep_in.is_none() => ep_in = Some(ep.address()),
            _ => {}
        }
    }
    let ep_out = ep_out.ok_or("PICOBOOT has no bulk OUT endpoint")?;
    let ep_in = ep_in.ok_or("PICOBOOT has no bulk IN endpoint")?;

    let mut writer = iface
        .endpoint::<nusb::transfer::Bulk, nusb::transfer::Out>(ep_out)
        .map_err(|e| format!("cannot open bulk OUT {ep_out:#04x}: {e}"))?;
    let mut reader = iface
        .endpoint::<nusb::transfer::Bulk, nusb::transfer::In>(ep_in)
        .map_err(|e| format!("cannot open bulk IN {ep_in:#04x}: {e}"))?;

    // Clear any half-finished command state on the interface first.
    iface
        .control_out(
            nusb::transfer::ControlOut {
                control_type: nusb::transfer::ControlType::Vendor,
                recipient: nusb::transfer::Recipient::Interface,
                request: IF_RESET,
                value: 0,
                index: iface_num as u16,
                data: &[],
            },
            TIMEOUT,
        )
        .wait()
        .map_err(|e| format!("IF_RESET failed: {e}"))?;

    // Exclusive access, so nothing else races the erase. 1 = exclusive.
    run(&mut writer, &mut reader, 1, "EXCLUSIVE_ACCESS", CMD_EXCLUSIVE_ACCESS, &[1])?;
    // Leave execute-in-place so flash becomes writable.
    run(&mut writer, &mut reader, 2, "EXIT_XIP", CMD_EXIT_XIP, &[])?;
    // Erase from the flash XIP base. args = dAddr(u32) + dSize(u32), and
    // dAddr is ABSOLUTE (0x10000000), not a zero offset — picotool's own
    // source passes the absolute address, and a zero is what the bootrom
    // STALLs on. Confirmed against picoboot_connection.c.
    let mut ea = [0u8; 8];
    ea[0..4].copy_from_slice(&FLASH_BASE.to_le_bytes());
    ea[4..8].copy_from_slice(&size.to_le_bytes());
    run(&mut writer, &mut reader, 3, "FLASH_ERASE", CMD_FLASH_ERASE, &ea)?;

    // No reboot here, and that is a lesson paid for. A PICOBOOT REBOOT
    // (pc=0/sp=0) after the erase left the board in a BOOTSEL that does not
    // *consume* dragged UF2s — copies piled up on the drive unflashed, on Linux
    // exactly as they had on the phone. The verified recovery (exp141's
    // recover.html) erases and stops, and the human replugs; that replug is
    // what gives a normal, UF2-consuming BOOTSEL. Until a correct
    // reboot-to-BOOTSEL is worked out, erase-and-replug is the proven path.
    Ok(format!(
        "erased {size} bytes of flash from offset 0 over PICOBOOT. The partition \
         table is gone. Now UNPLUG AND REPLUG the board — that gives a clean \
         BOOTSEL that accepts a UF2 — then `yi26 flash <file>` or drag one on."
    ))
}
