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
    ea[0..4].copy_from_slice(&0x1000_0000u32.to_le_bytes());
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
