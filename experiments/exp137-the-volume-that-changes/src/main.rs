//! exp137 — a volume whose contents change while the host is looking at it.
//!
//! Every volume this repository has served was laid down once at boot and
//! never touched again. [`docs/platforms.md`](../../docs/platforms.md) says
//! why, and names the missing piece:
//!
//! > Appending to a file after the host has mounted the volume means fighting
//! > the thing that makes mounting fast: the host caches sectors, so bytes the
//! > device writes afterwards are simply not read. Real devices answer that
//! > with a media-change signal — SCSI `UNIT ATTENTION` — which this
//! > repository has never sent and therefore cannot claim works.
//!
//! This firmware sends it. `STATUS.TXT` carries a generation number, one byte
//! on the serial port lays the whole volume down again with the next one, and
//! the next SCSI command the host issues is refused with **`06/28` — NOT READY
//! TO READY CHANGE, MEDIUM MAY HAVE CHANGED**.
//!
//! # What is already here, and what is one line
//!
//! Almost all of it was already here. exp123 taught this lineage to answer
//! `REQUEST SENSE` at all, and exp130 used `CHECK CONDITION` with sense
//! `07/27` to refuse a write. A media change is the same machinery pointed at
//! a different moment: `set_sense(0x06, 0x28)` and a failed status on the next
//! command, whatever that command is.
//!
//! The interesting part is not sending it. It is what a host does about it.
//!
//! # The signal is a notification, not an instruction
//!
//! `UNIT ATTENTION` says *something happened that you were not told about*.
//! Nothing obliges a host to re-read anything, and a mounted filesystem has
//! every reason not to: its page cache is the whole reason mounting is fast,
//! and the bytes underneath a mounted volume are not supposed to move.
//!
//! So there are two questions, and this experiment keeps them apart:
//!
//! 1. **Unmounted** — does the host re-read the disk after the signal?
//! 2. **Mounted** — does a file's contents change under a filesystem that has
//!    already read them?
//!
//! They can have different answers, and the second one being *no* would not
//! make the first one useless. `check.sh` measures both and reports both.
//!
//! # Two commands are exempt, and it is not politeness
//!
//! `INQUIRY` asks what the device *is*, which a medium change cannot affect,
//! and `REQUEST SENSE` is how the host collects the reason for a failure —
//! failing that one would hide the message being sent. Everything else is
//! refused once, and exactly once.
//!
//! # The whole volume is re-laid, and that is the honest thing to do
//!
//! Not the one file that changed. `UNIT ATTENTION` is a claim about the
//! medium, not about a file, and patching one file's clusters in place would
//! be a smaller change than the signal announces. The cost is that anything
//! the host wrote is gone — on a read-only volume that is only ever Android's
//! `LOST.DIR`, which exp126 measured arriving within a minute of mounting.

#![no_std]
#![no_main]

use core::fmt::Write as _;
use core::sync::atomic::{AtomicBool, AtomicU32, Ordering};

use embassy_executor::Spawner;
use embassy_futures::select::{select, Either};
use embassy_rp::bind_interrupts;
use embassy_rp::gpio::{Level, Output};
use embassy_rp::peripherals::USB;
use embassy_rp::usb::{Driver, Endpoint, In, InterruptHandler, Out};
use embassy_time::{Duration, Instant, Timer};
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

/// The repository's log tool, embedded from the file itself.
///
/// `include_bytes!` rather than a copy: two copies of a nineteen-kilobyte
/// page would drift, and the one on the board is the one nobody would think
/// to check. `check.sh` asserts the two files are byte-identical, which is
/// only meaningful because this is the same file.
const INDEX_HTM: &[u8] = include_bytes!("../../../tools/pages/log.html");

/// The way back, embedded from the maintained tool.
///
/// Mandatory rather than thoughtful: this firmware serves a volume and can be
/// rebooted by software, and [exp131] made that combination carry the page
/// that reboots it. A phone that flashed this board looks in one place for the
/// way to flash the next one.
///
/// [exp131]: ../../exp131-the-volume-is-the-app-drawer/
///
/// **Two names, on purpose.** The tool is `bootsel.html`, because in a directory
/// beside `pflash.html` a name has to say which of the two it is. On this
/// volume it is `FLASH.HTM`, beside `INDEX.HTM` and `LOG.HTM` — three answers
/// to *what does it do*, *how do I read it*, *how do I replace it*, read by
/// somebody holding a phone who has not been told what BOOTSEL is. Precision
/// there would cost more than it bought. See `tools/pages/README.md`.
const FLASH_HTM: &[u8] = include_bytes!("../../../tools/pages/bootsel.html");

/// The file that changes, and the only reason this experiment exists.
///
/// Its bytes are rendered at every re-lay rather than embedded, so what the
/// host reads back is evidence of *which* lay-down it read. `README.TXT` in
/// the earlier volumes was a constant; this one carries a generation number
/// that the host cannot have cached from before it existed.
const STATUS_NAME: &[u8; 11] = b"STATUS  TXT";

/// The other file on the volume.
///
/// CR+LF, because a file that only a Linux host will ever read is not the
/// point — this volume is meant to be opened by whatever is in front of you,
/// and Notepad on an older Windows still cares.
const README: &[u8] = b"exp137 - a volume whose contents change while you are looking at it.\r\n\r\nSTATUS.TXT carries a generation number. Send 'b' to this board's serial\r\nport and the firmware lays the volume down again with the next one, then\r\nreports a media change - SCSI UNIT ATTENTION - to the host.\r\n\r\nWhether you then see the new number depends on something this file cannot\r\ntell you: whether your host re-read the disk, or answered you out of the\r\ncache it made when it mounted. That is the measurement.\r\n\r\nOpen INDEX.HTM for the log, FLASH.HTM to put something else on the board.\r\n";

/// SCSI sense, kept so that `REQUEST SENSE` can answer the question the host
/// actually asks after a failure: *why*.
///
/// exp123 failed that question too, which is why its host learned nothing and
/// simply retried. Answering it is most of the difference between a device
/// that is refused and a device that is understood.
static SENSE_KEY: AtomicU32 = AtomicU32::new(0);
static SENSE_ASC: AtomicU32 = AtomicU32::new(0);

/// How many times the host has asked for a new volume, and how many times the
/// storage task has delivered one. Two counters rather than a flag: the
/// difference is a request in flight, and a task that owns `disk` can act on
/// it without anything else being allowed to touch those bytes.
static BUMPS_REQUESTED: AtomicU32 = AtomicU32::new(0);
static GENERATION: AtomicU32 = AtomicU32::new(1);

/// Set when the volume has been re-laid and no host command has been told yet.
///
/// SCSI's rule, and it is a rule about *timing* rather than about data: the
/// device reports a media change on the next command it is given, whatever
/// that command is, and reports it exactly once.
static MEDIA_CHANGED: AtomicBool = AtomicBool::new(false);

/// `TEST UNIT READY`, which is polled and not logged. See the dispatch.
static POLLS: AtomicU32 = AtomicU32::new(0);

static COMMANDS: AtomicU32 = AtomicU32::new(0);
static BLOCKS_READ: AtomicU32 = AtomicU32::new(0);
static BLOCKS_WRITTEN: AtomicU32 = AtomicU32::new(0);

/// UNIT ATTENTION / NOT READY TO READY CHANGE, MEDIUM MAY HAVE CHANGED.
///
/// The whole vocabulary this experiment adds. `0x06` is the key a device uses
/// to say *something happened that you were not told about*, and `0x28` is the
/// one that means the medium is not the medium you were reading.
const SENSE_UNIT_ATTENTION: u32 = 0x06;
const ASC_MEDIUM_MAY_HAVE_CHANGED: u32 = 0x28;

/// DATA PROTECT / WRITE PROTECTED, for a volume that declared itself read-only.
const SENSE_DATA_PROTECT: u32 = 0x07;
const ASC_WRITE_PROTECTED: u32 = 0x27;

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
            // One command, one byte, exp127's shape. It does not do the work:
            // the bytes of the volume belong to the storage task and nothing
            // else may touch them, so this only asks. exp118's rule about
            // ownership deciding the shape of a program, applied to a buffer
            // instead of to an endpoint.
            Either::Second(Ok(n)) if n > 0 => {
                if buf[..n].contains(&b'b') {
                    let want = BUMPS_REQUESTED.fetch_add(1, Ordering::Relaxed) + 1;
                    log!("asked for a new volume (request {})", want);
                } else {
                    log!("send 'b' to lay the volume down again; got {} other bytes", n);
                }
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
const INQUIRY_PRODUCT: &[u8; 16] = b"exp137 changing ";

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
/// host cares about.
///
/// Set here, unlike exp126, and for this experiment's own reason: a volume
/// that is laid down again from the device side would silently eat whatever
/// the host had written. Declaring it read-only means the host never writes,
/// so "the volume changed" has exactly one cause and the measurement has one
/// variable. exp130 established that a host which reads this bit does honour
/// it.
fn mode_sense6(out: &mut [u8]) -> usize {
    out[..4].fill(0);
    out[0] = 3; // mode data length, not counting itself
    out[2] = 0x80; // WP
    4
}

/// Lay the whole volume down again, with `generation` in `STATUS.TXT`.
///
/// The whole volume, not the one file that changed. That is deliberate and it
/// is what the signal underneath means: `UNIT ATTENTION` says *the medium may
/// have changed*, which is a claim about the disk rather than about a file.
/// Patching one file's clusters in place would be a smaller lie for the same
/// signal, and this experiment is about what the signal buys, so it tells the
/// truth about what it did.
///
/// The cost is real and worth knowing: anything the host wrote is gone. On a
/// read-only volume that is only ever Android's `LOST.DIR`, which exp126
/// measured arriving within a minute of mounting.
fn lay_down(disk: &mut [u8], generation: u32) -> u32 {
    let mut status = [0u8; 128];
    let mut w = Cursor { buf: &mut status, len: 0 };
    let _ = write!(
        w,
        "generation {}\r\nlaid down at {} ms since boot\r\n",
        generation,
        Instant::now().as_millis()
    );
    let len = w.len;

    fat12::format(
        disk,
        b"YI26 EXP137",
        &[
            fat12::File { name: b"INDEX   HTM", contents: INDEX_HTM },
            fat12::File { name: b"FLASH   HTM", contents: FLASH_HTM },
            fat12::File { name: STATUS_NAME, contents: &status[..len] },
            fat12::File { name: b"README  TXT", contents: README },
        ],
    )
    .expect("checked by the crate's own tests, and by check.sh against the real page sizes")
}

/// A `core::fmt::Write` over a fixed slice, so `STATUS.TXT` can be rendered
/// without a heap. It truncates rather than panicking; the buffer is four
/// times what the text needs.
struct Cursor<'a> {
    buf: &'a mut [u8],
    len: usize,
}

impl core::fmt::Write for Cursor<'_> {
    fn write_str(&mut self, s: &str) -> core::fmt::Result {
        let b = s.as_bytes();
        let room = self.buf.len() - self.len;
        let n = if b.len() < room { b.len() } else { room };
        self.buf[self.len..self.len + n].copy_from_slice(&b[..n]);
        self.len += n;
        Ok(())
    }
}

/// The thirteen bytes that end every command, in one place.
///
/// It was written inline, once, at the bottom of the loop — until a command
/// had to be answered from the middle of it. Two copies of a status wrapper is
/// two places for a residue to be computed differently, and a wrong residue is
/// a host that waits.
async fn send_csw(
    write_ep: &mut Endpoint<'static, USB, In>,
    tag: u32,
    residue: u32,
    status: u8,
) -> bool {
    let mut csw = [0u8; CSW_LEN];
    csw[0..4].copy_from_slice(&CSW_SIGNATURE.to_le_bytes());
    csw[4..8].copy_from_slice(&tag.to_le_bytes());
    csw[8..12].copy_from_slice(&residue.to_le_bytes());
    csw[12] = status;
    write_ep.write(&csw).await.is_ok()
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
    // What this task has already acted on. The host's counter only ever goes
    // up, so a difference is a request and nothing has to be reset.
    let mut delivered = 0u32;

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

            // Before anything is answered: if the host asked for a new
            // volume, this is the only place allowed to make one, because
            // this task owns the bytes.
            let asked = BUMPS_REQUESTED.load(Ordering::Relaxed);
            if asked != delivered {
                delivered = asked;
                let generation = GENERATION.fetch_add(1, Ordering::Relaxed) + 1;
                let clusters = lay_down(disk, generation);
                MEDIA_CHANGED.store(true, Ordering::Relaxed);
                log!(
                    "volume laid down again: generation {}, {} clusters used",
                    generation,
                    clusters
                );
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

            // The media change, reported exactly once, on whatever command
            // happens to arrive next.
            //
            // Two commands are exempt and the exemption is not politeness.
            // `INQUIRY` asks what the device *is*, which a medium cannot
            // change, and `REQUEST SENSE` is how the host collects the reason
            // for the failure — failing that one would hide the very message
            // being sent. Everything else is refused, the host asks why, and
            // the answer is `06/28`.
            //
            // What it costs the host to ignore this is nothing: it is a
            // notification, not an instruction. Whether any host acts on it is
            // the measurement, and the firmware's job is only to have said it.
            if MEDIA_CHANGED.load(Ordering::Relaxed) && op != 0x12 && op != 0x03 {
                MEDIA_CHANGED.store(false, Ordering::Relaxed);
                set_sense(SENSE_UNIT_ATTENTION, ASC_MEDIUM_MAY_HAVE_CHANGED);
                status = CSW_FAILED;
                log!(
                    "{}  -> UNIT ATTENTION (06/28): the medium may have changed",
                    opcode_name(op)
                );
                // A failed command still owes the host its data phase, even
                // though there is no data. exp124 learned this the hard way:
                // a host that asked for bytes and is given neither bytes nor
                // a refusal simply waits.
                if want > 0 && to_host {
                    let _ = write_ep.write(&[]).await;
                }
                if !send_csw(&mut write_ep, tag, want, status).await {
                    break;
                }
                continue;
            }

            match op {
                // No data, and the answer is "yes" because there is a disk.
                //
                // `TEST UNIT READY` is not logged, and that is a change this
                // experiment forced. A host polls it about twice a second
                // forever — it is how a host asks "is the medium still the
                // one I know about" — so logging it costs the log. The first
                // run of this firmware buried its own measurement under 135
                // dropped lines, which is exp134's queue arriving as a
                // consequence for the second time. Counted here, reported in
                // the idle line, never printed on its own.
                0x00 => {
                    set_sense(0, 0);
                    POLLS.fetch_add(1, Ordering::Relaxed);
                }

                0x1b | 0x1e | 0x35 => {
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

                0x2a => {
                    // Refused with a reason, not ignored. The host asked to
                    // write to a volume that told it not to, and the only
                    // useful answer names the rule it broke.
                    set_sense(SENSE_DATA_PROTECT, ASC_WRITE_PROTECTED);
                    status = CSW_FAILED;
                    log!("WRITE(10)  -> DATA PROTECT / WRITE PROTECTED");
                }

                0x28 => {
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
            if !send_csw(&mut write_ep, tag, want.saturating_sub(sent), status).await {
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
            log!("idle: nothing has asked for this volume yet");
        } else {
            // The generation belongs here rather than only at boot, for the
            // same reason exp136's scheme does: the line that says what the
            // capture means has to be the line that repeats.
            log!(
                "idle: generation {}, {} commands ({} polls), {} blocks read",
                GENERATION.load(Ordering::Relaxed),
                n,
                POLLS.load(Ordering::Relaxed),
                BLOCKS_READ.load(Ordering::Relaxed)
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
    config.product = Some("exp137 the volume that changes");
    config.serial_number = Some("137");
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
    // Generation 1, by the same function that lays down every later one. Two
    // code paths for "the volume at boot" and "the volume after a change" is
    // how the two drift apart, and the drift would be invisible: both produce
    // a volume that mounts.
    let clusters = lay_down(disk, GENERATION.load(Ordering::Relaxed));
    spawner.spawn(storage_task(read_ep, write_ep, disk).unwrap());
    spawner.spawn(idle_task().unwrap());

    log!(
        "exp137 up. {} KiB volume, generation {}. Send 'b' to lay it down again.",
        DISK_BYTES / 1024,
        GENERATION.load(Ordering::Relaxed)
    );
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
