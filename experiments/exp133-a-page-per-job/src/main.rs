//! exp126 — the board carries its own debug interface.
//!
//! Plug this board into anything with a browser and a file manager, and the
//! page that reads its log is already on it. No download, no repository, no
//! second computer — `INDEX.HTM` on a volume the firmware synthesises out of
//! its own SRAM.
//!
//! # This closes a loop that opened in exp101
//!
//! The `RP2350` drive that appears when you hold BOOTSEL is not a real disk.
//! The bootrom synthesises a FAT volume on the fly, complete with
//! `INFO_UF2.TXT` and an `INDEX.HTM` that points at Raspberry Pi's
//! documentation. ARM's DAPLink firmware does the same thing with `MBED.HTM`.
//!
//! exp101 met that drive and used it without asking what it was. This is what
//! it was. The trick that made the first experiment work is the one the last
//! experiment builds.
//!
//! # The page is exp116's, byte for byte
//!
//! Not a copy — `include_bytes!` pointing at
//! `../exp116-webusb-cdc-log/cdc-log-viewer.html`, so the two cannot drift
//! apart and `check.sh` asserts they are identical. Whatever exp116's page
//! does, this one does, because it *is* that file.
//!
//! # What this needed that exp125 did not
//!
//! A chain. exp125's file was 324 bytes and fitted in one cluster, so its
//! directory entry pointed at the only cluster the file had and the file
//! allocation table was never asked a question. This page is nineteen
//! kilobytes — thirty-eight clusters — and the directory entry holds only the
//! *first* of them.
//!
//! That is what the table is for, and why the crate that lays it out now has
//! tests for chains, for two files not colliding, and for refusing a file that
//! does not fit. A volume whose chain is wrong still mounts.

#![no_std]
#![no_main]

use core::sync::atomic::{AtomicBool, AtomicU32, Ordering};

use embassy_executor::Spawner;
use embassy_futures::select::{select, Either};
use embassy_rp::bind_interrupts;
use embassy_rp::gpio::{Level, Output};
use embassy_rp::peripherals::{TRNG, USB};
use embassy_rp::trng::{Config as TrngConfig, InterruptHandler as TrngInterruptHandler, Trng};
use embassy_rp::usb::{Driver, Endpoint, In, InterruptHandler, Out};
use embassy_time::{Duration, Timer};
use embassy_usb::class::cdc_acm::{CdcAcmClass, ControlChanged, Receiver, Sender, State};
use embassy_usb::driver::{Endpoint as _, EndpointIn, EndpointOut};
use embassy_usb::{Builder, Config as UsbConfig, UsbDevice};
use panic_halt as _;
use rp2350_linker as _;
use entropy_health::Health;
use static_cell::StaticCell;
use usb_log::log;

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
    TRNG_IRQ => TrngInterruptHandler<TRNG>;
});

const PACKET: usize = 64;
const IDLE_REPORT: Duration = Duration::from_secs(5);

const CLASS_MSC: u8 = 0x08;
const SUBCLASS_SCSI: u8 = 0x06;
const PROTOCOL_BOT: u8 = 0x50;

const CBW_SIGNATURE: u32 = 0x4342_5355;
const CSW_SIGNATURE: u32 = 0x5342_5355;
const CBW_LEN: usize = 31;
const CSW_LEN: usize = 13;
const CBW_FLAG_IN: u8 = 0x80;

const CSW_GOOD: u8 = 0x00;
const CSW_FAILED: u8 = 0x01;

/// 512 bytes, because everything above assumes it.
///
/// A SCSI disk may declare any block size and `READ CAPACITY` says which. In
/// practice partition tables, filesystems and the tools that read them are
/// written for 512, and a device that picks something else discovers how much
/// software only *believes* it is asking.
const BLOCK: usize = 512;

/// A small disk, entirely in RAM.
///
/// 64 KiB is enough to be a real volume with a real partition sector, small
/// enough to sit in SRAM without thought, and distinctive in `lsblk` — a
/// removable disk that size is unmistakably this experiment and not somebody's
/// USB stick.
const DISK_BLOCKS: u32 = 128;
const DISK_BYTES: usize = DISK_BLOCKS as usize * BLOCK;

/// exp116's page, embedded from the file itself.
///
/// `include_bytes!` rather than a copy: two copies of a nineteen-kilobyte
/// page would drift, and the one on the board is the one nobody would think
/// to check. `check.sh` asserts the two files are byte-identical, which is
/// only meaningful because this is the same file.
/// The appliance page, and the point of this experiment: it contains no log
/// code at all. It claims the vendor interface, sends a range, reads a reply.
/// exp130's page had to carry a log pane and a JSON exporter because on one
/// channel the log could not live anywhere else; this one does not, and the
/// difference is what a second interface buys.
const INDEX_HTM: &[u8] = include_bytes!("../index.html");

/// How to replace the firmware, from the volume the firmware serves.
///
/// This is the file that makes the claim true. Without it, a phone that wants
/// to flash the next build has to go and find a page somewhere — a repository
/// it may not have, or a download folder — and at that point the device is no
/// longer self-contained. exp117's page, byte for byte.
const FLASH_HTM: &[u8] = include_bytes!("../../exp117-webusb-reboot/reboot.html");

/// And the log viewer, back, unchanged, and independent again.
///
/// exp131 had to remove this: its appliance page held the only CDC pair, so
/// opening this one always failed. Here the appliance is on the vendor
/// interface and this has CDC to itself — measured in exp132, including with
/// the tab in the background. It is exp116's file, byte for byte, and it knows
/// nothing whatever about prize draws.
const LOG_HTM: &[u8] = include_bytes!("../../exp116-webusb-cdc-log/cdc-log-viewer.html");

/// The other file on the volume.
///
/// CR+LF, because a file that only a Linux host will ever read is not the
/// point — this volume is meant to be opened by whatever is in front of you,
/// and Notepad on an older Windows still cares.
const README: &[u8] = b"exp133 - three tools on one drive, and you can use them at once.\r\n\r\nINDEX.HTM   the prize draw. It talks on a channel of its own, so opening\r\n            it does not stop anything else working.\r\n\r\nLOG.HTM     the board own log, live. Open this one FIRST and connect it,\r\n            then draw in the other tab: the log keeps reading while it is\r\n            in the background, and you will see every draw arrive.\r\n\r\nFLASH.HTM   put the board into its bootloader. A drive named RP2350\r\n            replaces this one; copy a .uf2 onto it.\r\n\r\nNeither page knows anything about the other. That is the point: the log\r\nviewer works against any firmware here, and the draw page carries no log\r\ncode at all.\r\n\r\nChromium only. On Linux run 'yi26 detach' first; on a phone open them from\r\nthe Files app, never by typing a file:// address.\r\n";

/// SCSI sense, kept so that `REQUEST SENSE` can answer the question the host
/// actually asks after a failure: *why*.
///
/// exp123 failed that question too, which is why its host learned nothing and
/// simply retried. Answering it is most of the difference between a device
/// that is refused and a device that is understood.
/// exp109's number, not the driver's default, which is wrong here by a factor
/// of thousands.
const TRNG_SAMPLE_COUNT: u32 = 1000;

/// Bytes fetched per draw, and therefore bits health-tested per draw.
const DRAW_BYTES: usize = 64;

/// Bits pushed before the first draw is allowed. Two adaptive-proportion
/// windows, because a gate that has not had the chance to fail is not a gate.
const WARMUP_BITS: u32 = 2 * entropy_health::APT_WINDOW;

/// The longest command this firmware will assemble, using exp128's rule.
const MESSAGE: usize = 128;

/// Bumped whenever `draw.html` changes, and printed at boot.
///
/// The page knows its own build and compares. This closes a gap that is
/// otherwise invisible: a page opened off the board's volume and a stale copy
/// saved on the phone weeks ago look identical in the address bar.
const PAGE_BUILD: &str = "b2";

/// The vendor interface's class triple. 0xFF promises nothing, so no driver
/// claims it and a page can — established with libusb in exp122 and with a
/// browser in exp132.
const CLASS_VENDOR: u8 = 0xFF;
const SUBCLASS_NONE: u8 = 0x00;
const PROTOCOL_NONE: u8 = 0x00;

static DRAWS: AtomicU32 = AtomicU32::new(0);
static REFUSED: AtomicU32 = AtomicU32::new(0);
static BITS_TESTED: AtomicU32 = AtomicU32::new(0);
static HEALTH_FAILED: AtomicBool = AtomicBool::new(false);

static SENSE_KEY: AtomicU32 = AtomicU32::new(0);
static SENSE_ASC: AtomicU32 = AtomicU32::new(0);

static COMMANDS: AtomicU32 = AtomicU32::new(0);
static BLOCKS_READ: AtomicU32 = AtomicU32::new(0);
static BLOCKS_WRITTEN: AtomicU32 = AtomicU32::new(0);

/// ILLEGAL REQUEST / INVALID COMMAND OPERATION CODE.
const SENSE_ILLEGAL_REQUEST: u32 = 0x05;
const ASC_INVALID_COMMAND: u32 = 0x20;
/// ILLEGAL REQUEST / LOGICAL BLOCK ADDRESS OUT OF RANGE.
const ASC_LBA_OUT_OF_RANGE: u32 = 0x21;
/// DATA PROTECT / WRITE PROTECTED — the pair a host expects when it is
/// told no. Refusing with the wrong sense is how a device gets retried
/// instead of understood; exp123 is the whole experiment about that.
const SENSE_DATA_PROTECT: u32 = 0x07;
const ASC_WRITE_PROTECTED: u32 = 0x27;

fn le_u32(b: &[u8]) -> u32 {
    u32::from_le_bytes([b[0], b[1], b[2], b[3]])
}

/// SCSI's byte order, and the reason this has a name of its own.
fn be_u32(b: &[u8]) -> u32 {
    u32::from_be_bytes([b[0], b[1], b[2], b[3]])
}

fn be_u16(b: &[u8]) -> u16 {
    u16::from_be_bytes([b[0], b[1]])
}

fn opcode_name(op: u8) -> &'static str {
    match op {
        0x00 => "TEST UNIT READY",
        0x03 => "REQUEST SENSE",
        0x12 => "INQUIRY",
        0x1a => "MODE SENSE(6)",
        0x1b => "START STOP UNIT",
        0x1e => "PREVENT ALLOW MEDIUM REMOVAL",
        0x23 => "READ FORMAT CAPACITIES",
        0x25 => "READ CAPACITY(10)",
        0x28 => "READ(10)",
        0x2a => "WRITE(10)",
        0x35 => "SYNCHRONIZE CACHE(10)",
        0x5a => "MODE SENSE(10)",
        _ => "unsupported",
    }
}

#[embassy_executor::task]
async fn usb_task(mut device: UsbDevice<'static, Driver<'static, USB>>) -> ! {
    device.run().await
}

#[embassy_executor::task]
async fn log_task(sender: Sender<'static, usb_reboot::UsbDriver>) -> ! {
    usb_log::run(sender).await
}

#[embassy_executor::task]
async fn console_task(
    control: ControlChanged<'static>,
    mut receiver: Receiver<'static, usb_reboot::UsbDriver>,
) -> ! {
    let mut buf = [0u8; PACKET];
    loop {
        match select(control.control_changed(), receiver.read_packet(&mut buf)).await {
            Either::First(()) => {
                usb_reboot::reboot_if_requested(receiver.line_coding().data_rate()).await;
            }
            // This interface carries the log and the 1200-baud touch, and no
            // longer carries commands. Somebody who sends a range here needs
            // telling which channel it moved to, not silence.
            Either::Second(Ok(n)) if n > 0 => {
                log!("{} bytes on the log channel — commands moved to the", n);
                log!("  vendor interface: open INDEX.HTM, or  yi26 echo 2100-2567");
            }
            Either::Second(_) => {}
        }
    }
}

/// The command channel, and the reason the appliance page needs no log code.
///
/// One command per packet, one answer per command. The answers go out here and
/// into the log both — so a page holding this interface and a page holding the
/// CDC one see the same event, which is exp132's measurement turned into a
/// device somebody would use.
#[embassy_executor::task]
async fn vendor_task(
    mut read_ep: Endpoint<'static, USB, Out>,
    mut write_ep: Endpoint<'static, USB, In>,
    mut trng: Trng<'static, TRNG>,
) -> ! {
    let mut health = Health::new();
    warm_up(&mut trng, &mut health).await;

    let mut buf = [0u8; PACKET];
    loop {
        read_ep.wait_enabled().await;
        loop {
            let n = match read_ep.read(&mut buf).await {
                Ok(n) => n,
                Err(_) => break,
            };
            if n == 0 {
                continue;
            }
            let mut reply = Reply::new();
            handle(&buf[..n], &mut trng, &mut health, &mut reply).await;
            let _ = write_ep.write(reply.as_bytes()).await;
        }
    }
}

/// Pushes bits through the health tests until a window has closed.
async fn warm_up(trng: &mut Trng<'static, TRNG>, health: &mut Health) {
    let mut warm = [0u8; 128];
    while health.total() < WARMUP_BITS {
        trng.fill_bytes(&mut warm).await;
        for &byte in warm.iter() {
            for i in 0..8 {
                if health.push((byte >> i) & 1 == 1).is_some() {
                    HEALTH_FAILED.store(true, Ordering::Relaxed);
                }
            }
        }
    }
    BITS_TESTED.store(health.total(), Ordering::Relaxed);
    if HEALTH_FAILED.load(Ordering::Relaxed) {
        log!("health tests failed during warmup — this board will not draw");
    } else {
        log!("warmed up: {} bits through the health tests", health.total());
    }
}

/// A line built on the stack, for the channel that answers as well as logs.
struct Reply {
    buf: [u8; PACKET],
    len: usize,
}

impl Reply {
    fn new() -> Self {
        Self { buf: [0; PACKET], len: 0 }
    }
    fn as_bytes(&self) -> &[u8] {
        &self.buf[..self.len]
    }
}

impl core::fmt::Write for Reply {
    fn write_str(&mut self, s: &str) -> core::fmt::Result {
        let b = s.as_bytes();
        let room = PACKET - self.len;
        let n = if b.len() < room { b.len() } else { room };
        self.buf[self.len..self.len + n].copy_from_slice(&b[..n]);
        self.len += n;
        Ok(())
    }
}

/// One command, one answer.
///
/// `?` is here because of what splitting the channels took away. exp130's page
/// checked its own provenance by reading the firmware's build string off the
/// boot log — and a page that holds only the vendor interface never sees that
/// log. Without a way to ask, the appliance page would lose the one protection
/// that tells somebody they are looking at a stale copy saved on their phone.
/// So the command channel answers the question directly.
async fn handle(
    msg: &[u8],
    trng: &mut Trng<'static, TRNG>,
    health: &mut Health,
    reply: &mut Reply,
) {
    use core::fmt::Write as _;

    if msg.first() == Some(&b'?') {
        let _ = write!(reply, "page build {}\n", PAGE_BUILD);
        return;
    }

    let Some((lo, hi)) = parse_range(msg) else {
        REFUSED.fetch_add(1, Ordering::Relaxed);
        log!("not a range: \"{}\"", Printable(&msg[..msg.len().min(32)]));
        let _ = write!(reply, "not a range\n");
        return;
    };
    if hi < lo {
        REFUSED.fetch_add(1, Ordering::Relaxed);
        log!("{}-{} is empty — lo must not be above hi", lo, hi);
        let _ = write!(reply, "{}-{} is empty\n", lo, hi);
        return;
    }
    match draw_one(trng, health, lo, hi).await {
        None => {
            REFUSED.fetch_add(1, Ordering::Relaxed);
            log!("refused: the health tests have failed — no number");
            let _ = write!(reply, "refused: health tests failed\n");
        }
        Some(Err(e)) => {
            REFUSED.fetch_add(1, Ordering::Relaxed);
            log!("refused: the draw could not complete ({:?})", e);
            let _ = write!(reply, "refused: draw incomplete\n");
        }
        Some(Ok(value)) => {
            let seq = DRAWS.fetch_add(1, Ordering::Relaxed) + 1;
            let span = hi - lo + 1;
            log!("draw #{}: {}  in {}-{} ({} values)", seq, value, lo, hi, span);
            let _ = write!(reply, "draw #{}: {}  in {}-{} ({} values)\n", seq, value, lo, hi, span);
        }
    }
}

/// Strict on purpose: a prize draw is a bad place for a parser that guesses.
fn parse_range(msg: &[u8]) -> Option<(u32, u32)> {
    let dash = msg.iter().position(|&b| b == b'-')?;
    Some((parse_u32(&msg[..dash])?, parse_u32(&msg[dash + 1..])?))
}

fn parse_u32(s: &[u8]) -> Option<u32> {
    if s.is_empty() || s.len() > 10 {
        return None;
    }
    let mut n: u32 = 0;
    for &b in s {
        let d = b.checked_sub(b'0')?;
        if d > 9 {
            return None;
        }
        n = n.checked_mul(10)?.checked_add(d as u32)?;
    }
    Some(n)
}

struct Printable<'a>(&'a [u8]);

impl core::fmt::Display for Printable<'_> {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        for &b in self.0 {
            f.write_str(if (0x20..0x7f).contains(&b) {
                core::str::from_utf8(core::slice::from_ref(&b)).unwrap_or(".")
            } else {
                "."
            })?;
        }
        Ok(())
    }
}

/// Fetch, test, then draw — in that order, so the bytes behind a number are
/// the bytes that were tested. exp129 works through why.
async fn draw_one(
    trng: &mut Trng<'static, TRNG>,
    health: &mut Health,
    lo: u32,
    hi: u32,
) -> Option<Result<u32, draw::Error>> {
    if HEALTH_FAILED.load(Ordering::Relaxed) {
        return None;
    }
    let mut bytes = [0u8; DRAW_BYTES];
    trng.fill_bytes(&mut bytes).await;
    for &byte in bytes.iter() {
        for i in 0..8 {
            if health.push((byte >> i) & 1 == 1).is_some() {
                HEALTH_FAILED.store(true, Ordering::Relaxed);
            }
        }
    }
    BITS_TESTED.store(health.total(), Ordering::Relaxed);
    if HEALTH_FAILED.load(Ordering::Relaxed) {
        return None;
    }
    let mut i = 0usize;
    Some(draw::in_range(lo, hi, || {
        let w = u32::from_le_bytes([bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]]);
        i += 4;
        w
    }))
}

fn set_sense(key: u32, asc: u32) {
    SENSE_KEY.store(key, Ordering::Relaxed);
    SENSE_ASC.store(asc, Ordering::Relaxed);
}

/// The 36-byte answer to "what are you".
///
/// The strings are fixed-width and space-padded, not NUL-terminated — SCSI
/// predates that convention. `lsblk` prints them as VENDOR and MODEL, so this
/// is where the name in the disk listing comes from.
/// The two strings a host shows in its disk listing.
///
/// Named once and used twice — in the bytes that go out and in the line that
/// says what went out. They were literals in both places for one build, the
/// bytes were updated and the log line was not, and the firmware spent that
/// build reporting a product name it was not sending. A log that disagrees
/// with the artifact is the failure this repository keeps meeting.
const INQUIRY_VENDOR: &[u8; 8] = b"yi26    ";
const INQUIRY_PRODUCT: &[u8; 16] = b"exp133 drawer   ";

fn inquiry(out: &mut [u8]) -> usize {
    out[..36].fill(0);
    out[0] = 0x00; // peripheral qualifier 0, direct-access block device
    out[1] = 0x80; // removable
    out[2] = 0x02; // SCSI-2
    out[3] = 0x02; // response data format 2
    out[4] = 31; // additional length: 36 - 5
    out[8..16].copy_from_slice(INQUIRY_VENDOR);
    out[16..32].copy_from_slice(INQUIRY_PRODUCT);
    out[32..36].copy_from_slice(b"0001");
    36
}

/// Fixed-format sense data: what went wrong with the previous command.
fn request_sense(out: &mut [u8]) -> usize {
    out[..18].fill(0);
    out[0] = 0x70; // current error, fixed format
    out[2] = SENSE_KEY.load(Ordering::Relaxed) as u8;
    out[7] = 10; // additional sense length
    out[12] = SENSE_ASC.load(Ordering::Relaxed) as u8;
    18
}

/// Last addressable block and block size — both big-endian.
///
/// `DISK_BLOCKS - 1`, not `DISK_BLOCKS`. READ CAPACITY reports the address of
/// the last block, not how many there are, and an off-by-one here is a disk
/// that is one block too large: the host will eventually read past the end and
/// find out.
fn read_capacity(out: &mut [u8]) -> usize {
    out[0..4].copy_from_slice(&(DISK_BLOCKS - 1).to_be_bytes());
    out[4..8].copy_from_slice(&(BLOCK as u32).to_be_bytes());
    8
}

/// A four-byte mode parameter header and no pages.
///
/// Byte 2 carries the write-protect bit, which is the only thing in here the
/// host cares about. Zero means writable.
fn mode_sense6(out: &mut [u8]) -> usize {
    out[..4].fill(0);
    out[0] = 3; // mode data length, not counting itself
    // Byte 2 is the device-specific parameter and bit 7 is WRITE PROTECT.
    // exp126 left this zero and the volume was writable, so Android created a
    // LOST.DIR on it within a minute of mounting — a host will write to your
    // device unless you tell it not to. A draw appliance should not be
    // scribbled on, so this one says no, and the WRITE below refuses too:
    // declaring read-only and then accepting writes would be a lie a host has
    // no way to catch.
    out[2] = 0x80;
    4
}

/// Reads command wrappers, serves them, and reports.
#[embassy_executor::task]
async fn storage_task(
    mut read_ep: Endpoint<'static, USB, Out>,
    mut write_ep: Endpoint<'static, USB, In>,
    disk: &'static mut [u8],
) -> ! {
    let mut buf = [0u8; PACKET];
    let mut reply = [0u8; 64];

    loop {
        read_ep.wait_enabled().await;

        loop {
            let n = match read_ep.read(&mut buf).await {
                Ok(n) => n,
                Err(_) => break,
            };
            if n != CBW_LEN || le_u32(&buf[0..4]) != CBW_SIGNATURE {
                log!("not a CBW: {} bytes", n);
                continue;
            }

            let tag = le_u32(&buf[4..8]);
            let want = le_u32(&buf[8..12]);
            let to_host = buf[12] & CBW_FLAG_IN != 0;
            let cb = [
                buf[15], buf[16], buf[17], buf[18], buf[19], buf[20], buf[21], buf[22], buf[23],
                buf[24],
            ];
            let op = cb[0];
            COMMANDS.fetch_add(1, Ordering::Relaxed);

            let mut status = CSW_GOOD;
            let mut sent: u32 = 0;

            match op {
                // No data, and the answer is "yes" because there is a disk.
                0x00 | 0x1b | 0x1e | 0x35 => {
                    set_sense(0, 0);
                    log!("{}  -> ok", opcode_name(op));
                }

                0x12 => {
                    let len = inquiry(&mut reply).min(want as usize);
                    let _ = write_ep.write(&reply[..len]).await;
                    sent = len as u32;
                    set_sense(0, 0);
                    log!(
                        "INQUIRY  -> {} bytes: {} / {}",
                        len,
                        core::str::from_utf8(INQUIRY_VENDOR).unwrap_or("?").trim_end(),
                        core::str::from_utf8(INQUIRY_PRODUCT).unwrap_or("?").trim_end()
                    );
                }

                0x03 => {
                    let len = request_sense(&mut reply).min(want as usize);
                    let _ = write_ep.write(&reply[..len]).await;
                    sent = len as u32;
                    log!(
                        "REQUEST SENSE  -> key {} asc {:02x}",
                        SENSE_KEY.load(Ordering::Relaxed),
                        SENSE_ASC.load(Ordering::Relaxed)
                    );
                }

                0x25 => {
                    let len = read_capacity(&mut reply).min(want as usize);
                    let _ = write_ep.write(&reply[..len]).await;
                    sent = len as u32;
                    set_sense(0, 0);
                    log!(
                        "READ CAPACITY  -> last LBA {}, {} bytes each = {} KiB",
                        DISK_BLOCKS - 1,
                        BLOCK,
                        DISK_BYTES / 1024
                    );
                }

                0x1a => {
                    let len = mode_sense6(&mut reply).min(want as usize);
                    let _ = write_ep.write(&reply[..len]).await;
                    sent = len as u32;
                    set_sense(0, 0);
                    log!("MODE SENSE(6)  -> READ-ONLY (WP set), no pages");
                }

                // Declared read-only in MODE SENSE, so refused here. A device
                // that says WP and then accepts a WRITE has told the host
                // something it cannot check, and the host will believe the
                // wrong one of the two.
                0x2a => {
                    set_sense(SENSE_DATA_PROTECT, ASC_WRITE_PROTECTED);
                    status = CSW_FAILED;
                    log!("WRITE(10)  -> refused, this volume is read-only");
                }

                0x28 => {
                    let lba = be_u32(&cb[2..6]);
                    let count = be_u16(&cb[7..9]) as u32;
                    let reading = true;

                    if lba.saturating_add(count) > DISK_BLOCKS {
                        // The failure that matters most, and the one a
                        // dishonest READ CAPACITY causes: refuse it precisely
                        // rather than reading off the end of an array.
                        set_sense(SENSE_ILLEGAL_REQUEST, ASC_LBA_OUT_OF_RANGE);
                        status = CSW_FAILED;
                        log!("{} lba {} +{}  -> OUT OF RANGE", opcode_name(op), lba, count);
                    } else {
                        let start = lba as usize * BLOCK;
                        let end = start + count as usize * BLOCK;
                        if reading {
                            for chunk in disk[start..end].chunks(PACKET) {
                                if write_ep.write(chunk).await.is_err() {
                                    break;
                                }
                            }
                            sent = (end - start) as u32;
                            BLOCKS_READ.fetch_add(count, Ordering::Relaxed);
                        } else {
                            let mut at = start;
                            while at < end {
                                match read_ep.read(&mut buf).await {
                                    Ok(got) => {
                                        let take = got.min(end - at);
                                        disk[at..at + take].copy_from_slice(&buf[..take]);
                                        at += take.max(1);
                                    }
                                    Err(_) => break,
                                }
                            }
                            sent = (end - start) as u32;
                            BLOCKS_WRITTEN.fetch_add(count, Ordering::Relaxed);
                        }
                        set_sense(0, 0);
                        log!("{} lba {} +{} blocks", opcode_name(op), lba, count);
                    }
                }

                // Everything else is refused with a reason the host can read.
                // exp123 refused these too, and refused REQUEST SENSE as well,
                // which is why its host learned nothing and retried.
                _ => {
                    set_sense(SENSE_ILLEGAL_REQUEST, ASC_INVALID_COMMAND);
                    status = CSW_FAILED;
                    if want > 0 && to_host {
                        let _ = write_ep.write(&[]).await;
                    }
                    log!("{:02x} {}  -> refused, invalid command", op, opcode_name(op));
                }
            }

            // A short reply is not a failure. The residue says how much of the
            // requested transfer did not happen, and a host that asked for 36
            // bytes and got 36 sees zero residue.
            let mut csw = [0u8; CSW_LEN];
            csw[0..4].copy_from_slice(&CSW_SIGNATURE.to_le_bytes());
            csw[4..8].copy_from_slice(&tag.to_le_bytes());
            csw[8..12].copy_from_slice(&want.saturating_sub(sent).to_le_bytes());
            csw[12] = status;
            if write_ep.write(&csw).await.is_err() {
                break;
            }
        }
    }
}

#[embassy_executor::task]
async fn idle_task() -> ! {
    loop {
        Timer::after(IDLE_REPORT).await;
        let n = COMMANDS.load(Ordering::Relaxed);
        if n == 0 {
            log!("idle: INDEX.HTM is on the volume; open it in a Chromium browser");
        } else {
            log!(
                "idle: {} commands, {} blocks read, {} written",
                n,
                BLOCKS_READ.load(Ordering::Relaxed),
                BLOCKS_WRITTEN.load(Ordering::Relaxed)
            );
        }
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let p = embassy_rp::init(Default::default());
    let mut led = Output::new(p.PIN_25, Level::Low);

    let driver = Driver::new(p.USB, Irqs);

    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some("exp133 a page per job");
    config.serial_number = Some("133");
    config.device_class = 0xef;
    config.device_sub_class = 0x02;
    config.device_protocol = 0x01;
    config.composite_with_iads = true;

    static CONFIG_DESCRIPTOR: StaticCell<[u8; 256]> = StaticCell::new();
    static BOS_DESCRIPTOR: StaticCell<[u8; 256]> = StaticCell::new();
    static CONTROL_BUF: StaticCell<[u8; 64]> = StaticCell::new();
    static ACM_STATE: StaticCell<State> = StaticCell::new();
    static DISK: StaticCell<[u8; DISK_BYTES]> = StaticCell::new();

    let mut builder = Builder::new(
        driver,
        config,
        CONFIG_DESCRIPTOR.init([0; 256]),
        BOS_DESCRIPTOR.init([0; 256]),
        &mut [],
        CONTROL_BUF.init([0; 64]),
    );

    let class = CdcAcmClass::new(&mut builder, ACM_STATE.init(State::new()), PACKET as u16);

    let (read_ep, write_ep) = {
        let mut function = builder.function(CLASS_MSC, SUBCLASS_SCSI, PROTOCOL_BOT);
        let mut interface = function.interface();
        let mut alt = interface.alt_setting(CLASS_MSC, SUBCLASS_SCSI, PROTOCOL_BOT, None);
        let out = alt.endpoint_bulk_out(None, PACKET as u16);
        let in_ = alt.endpoint_bulk_in(None, PACKET as u16);
        (out, in_)
    };

    // The third function, and the one this experiment is about. Four
    // interfaces now — CDC's two, mass storage, and this — which is the same
    // count the four-interface composites this repository already enumerates
    // cleanly have. exp121 measured what adding one does to every number in
    // the tree; nothing here depends on those numbers, because every page
    // asks the descriptors rather than remembering them.
    let (vendor_out, vendor_in) = {
        let mut function = builder.function(CLASS_VENDOR, SUBCLASS_NONE, PROTOCOL_NONE);
        let mut interface = function.interface();
        let mut alt = interface.alt_setting(CLASS_VENDOR, SUBCLASS_NONE, PROTOCOL_NONE, None);
        let out = alt.endpoint_bulk_out(None, PACKET as u16);
        let in_ = alt.endpoint_bulk_in(None, PACKET as u16);
        (out, in_)
    };

    let usb = builder.build();
    spawner.spawn(usb_task(usb).unwrap());

    let (sender, receiver, control) = class.split_with_control();
    spawner.spawn(log_task(sender).unwrap());
    let mut trng_config = TrngConfig::default();
    trng_config.sample_count = TRNG_SAMPLE_COUNT;
    let trng = Trng::new(p.TRNG, Irqs, trng_config);
    spawner.spawn(console_task(control, receiver).unwrap());
    spawner.spawn(vendor_task(vendor_out, vendor_in, trng).unwrap());

    // exp124 left this zeroed and the host found nothing, which was the point
    // there. Here the bytes of a filesystem are written into it before the
    // host is ever allowed to look.
    let disk = DISK.init([0u8; DISK_BYTES]);
    // INDEX.HTM first, so it starts at cluster 2 — the lowest-numbered, and
    // the one a reader tracing the chain by hand will look at first.
    let clusters = fat12::format(
        disk,
        b"YI26 TOOLS ",
        &[
            fat12::File { name: b"INDEX   HTM", contents: INDEX_HTM },
            fat12::File { name: b"LOG     HTM", contents: LOG_HTM },
            fat12::File { name: b"FLASH   HTM", contents: FLASH_HTM },
            fat12::File { name: b"README  TXT", contents: README },
        ],
    )
    .expect("checked by the crate's own tests, and by check.sh against the real page size");
    spawner.spawn(storage_task(read_ep, write_ep, disk).unwrap());
    spawner.spawn(idle_task().unwrap());

    log!("exp133 up. {} KiB read-only volume, three pages on it.", DISK_BYTES / 1024);
    // Printed so the page can compare it with its own. See PAGE_BUILD.
    log!("page build {}", PAGE_BUILD);
    log!(
        "{} clusters; INDEX.HTM is {} bytes, chained across {} of them",
        clusters,
        INDEX_HTM.len(),
        INDEX_HTM.len().div_ceil(BLOCK)
    );

    loop {
        led.set_high();
        Timer::after(Duration::from_millis(50)).await;
        led.set_low();
        Timer::after(Duration::from_millis(950)).await;
    }
}
