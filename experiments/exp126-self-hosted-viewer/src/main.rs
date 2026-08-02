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

use core::sync::atomic::{AtomicU32, Ordering};

use embassy_executor::Spawner;
use embassy_futures::select::{select, Either};
use embassy_rp::bind_interrupts;
use embassy_rp::gpio::{Level, Output};
use embassy_rp::peripherals::USB;
use embassy_rp::usb::{Driver, Endpoint, In, InterruptHandler, Out};
use embassy_time::{Duration, Timer};
use embassy_usb::class::cdc_acm::{CdcAcmClass, ControlChanged, Receiver, Sender, State};
use embassy_usb::driver::{Endpoint as _, EndpointIn, EndpointOut};
use embassy_usb::{Builder, Config as UsbConfig, UsbDevice};
use panic_halt as _;
use rp2350_linker as _;
use static_cell::StaticCell;
use usb_log::log;

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
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
const INDEX_HTM: &[u8] = include_bytes!("../../exp116-webusb-cdc-log/cdc-log-viewer.html");

/// The other file on the volume.
///
/// CR+LF, because a file that only a Linux host will ever read is not the
/// point — this volume is meant to be opened by whatever is in front of you,
/// and Notepad on an older Windows still cares.
const README: &[u8] = b"exp126 - this board carries its own debug interface.\r\n\r\nOpen INDEX.HTM in a Chromium browser. It claims this board's serial\r\ninterfaces and streams the firmware log, with no software installed and\r\nnothing downloaded - the page came off the board you are reading it from.\r\n\r\nOn Linux, run 'yi26 detach' first: the kernel's cdc_acm driver owns those\r\ninterfaces and an interface has exactly one owner. On Android there is no\r\ncdc_acm and nothing to move aside.\r\n\r\nThis volume is 64 KiB of the chip's own SRAM, laid out as FAT12 by hand\r\nat boot. The RP2350 bootloader drive you have already used does the same.\r\n";

/// SCSI sense, kept so that `REQUEST SENSE` can answer the question the host
/// actually asks after a failure: *why*.
///
/// exp123 failed that question too, which is why its host learned nothing and
/// simply retried. Answering it is most of the difference between a device
/// that is refused and a device that is understood.
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
            Either::Second(_) => {}
        }
    }
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
const INQUIRY_PRODUCT: &[u8; 16] = b"exp126 viewer   ";

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
                    log!("MODE SENSE(6)  -> writable, no pages");
                }

                0x28 | 0x2a => {
                    let lba = be_u32(&cb[2..6]);
                    let count = be_u16(&cb[7..9]) as u32;
                    let reading = op == 0x28;

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
    config.product = Some("exp126 self hosted viewer");
    config.serial_number = Some("126");
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

    let usb = builder.build();
    spawner.spawn(usb_task(usb).unwrap());

    let (sender, receiver, control) = class.split_with_control();
    spawner.spawn(log_task(sender).unwrap());
    spawner.spawn(console_task(control, receiver).unwrap());

    // exp124 left this zeroed and the host found nothing, which was the point
    // there. Here the bytes of a filesystem are written into it before the
    // host is ever allowed to look.
    let disk = DISK.init([0u8; DISK_BYTES]);
    // INDEX.HTM first, so it starts at cluster 2 — the lowest-numbered, and
    // the one a reader tracing the chain by hand will look at first.
    let clusters = fat12::format(
        disk,
        b"YI26 EXP126",
        &[
            fat12::File { name: b"INDEX   HTM", contents: INDEX_HTM },
            fat12::File { name: b"README  TXT", contents: README },
        ],
    )
    .expect("checked by the crate's own tests, and by check.sh against the real page size");
    spawner.spawn(storage_task(read_ep, write_ep, disk).unwrap());
    spawner.spawn(idle_task().unwrap());

    log!("exp126 up. {} KiB of SRAM, carrying its own debug page.", DISK_BYTES / 1024);
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
