#![no_std]
#![no_main]

use core::sync::atomic::{AtomicBool, AtomicU32, Ordering};

use embassy_executor::Spawner;
use embassy_futures::select::{select, Either};
use embassy_rp::bind_interrupts;
use embassy_rp::block::{
    item_generic_2bs, item_image_type_exe, Architecture, Block, Security, IMAGE_TYPE_TBYB,
    ITEM_1BS_VERSION,
};
use embassy_rp::gpio::{Level, Output};
use embassy_rp::peripherals::USB;
use embassy_rp::rom_data;
use embassy_rp::usb::{Driver, InterruptHandler};
use embassy_time::{Duration, Timer};
use embassy_usb::class::cdc_acm::{CdcAcmClass, ControlChanged, Receiver, Sender, State};
use embassy_usb::{Builder, Config as UsbConfig, UsbDevice};
use framing::{cobs, Deframer as _, Start as _};
use p256::ecdsa::signature::Verifier;
use p256::ecdsa::{Signature, VerifyingKey};
use panic_halt as _;
use rp2350_linker as _;
use sha2::{Digest, Sha256};
use static_cell::StaticCell;
use usb_log::log;

// SLOT ("A"/"B"), VERSION_MAJOR, VERSION_MINOR, TBYB, BUY — set by build.rs
// from the EXP167_* environment variables. Same source, four declarations.
include!(concat!(env!("OUT_DIR"), "/exp167_config.rs"));

/// The one bit that makes an image provisional, in the position the IMAGE_TYPE
/// item puts its value: `item_generic_1bs` shifts the 16-bit value up by 16.
const TBYB_BIT: u32 = if TBYB { (IMAGE_TYPE_TBYB as u32) << 16 } else { 0 };

/// This image's own IMAGE_DEF, at the start of its partition.
///
/// Three items' worth of words: the image type — with the **TBYB** bit set in
/// the B build, which is the whole experiment — and a VERSION the ROM compares
/// across the A/B pair. embassy-rp's default IMAGE_DEF is off (`imagedef-none`)
/// so this is the block the ROM reads.
///
/// `explicit_buy` **rewrites this block in flash** to clear the TBYB bit. That
/// is why the image type word is read back below through a volatile read rather
/// than trusted as a compile-time constant: after a buy, the bytes on the chip
/// and the bytes in the source no longer agree, and the chip is the truth.
#[link_section = ".start_block"]
#[used]
static IMAGE_DEF: Block<3> = Block::new([
    item_image_type_exe(Security::Secure, Architecture::Arm) | TBYB_BIT,
    item_generic_2bs(0, 2, ITEM_1BS_VERSION),
    ((VERSION_MAJOR as u32) << 16) | VERSION_MINOR as u32,
]);

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
});

const PACKET: usize = 64;

/// How long to wait before saying anything the reader must not miss. The log
/// queue holds lines written before the host opens the port, but only sixteen
/// of them (exp134 measured what that costs).
const SETTLE: Duration = Duration::from_secs(3);

/// Milliseconds between log lines. `usb-log` queues sixteen and drops the rest,
/// and exp166 lost forty-nine in one go when the drain stalled for 600 ms.
const PACE: Duration = Duration::from_millis(80);

/// How long a provisional image talks before it decides. Measured on hardware:
/// the ROM arms the trial clock at 16.775 s of its 16.777 s maximum, so there
/// is room for USB to enumerate (about a second) and for a reader to see this
/// happen — nothing here has to race the watchdog or feed it.
const TRIAL_TALK: Duration = Duration::from_secs(6);

/// After a buy: how long before the image resets itself, once, to show that a
/// plain reset now boots the slot that was provisional a minute ago. Nothing
/// else in this repository can reset a board without a hand or a reflash.
const PROVE_AFTER: Duration = Duration::from_secs(10);

const IDLE_REPORT: Duration = Duration::from_secs(5);

const BLINK_ON: Duration = Duration::from_millis(50);
const BLINK_OFF: Duration = Duration::from_millis(950);

/// `reboot` flags, §5.5.8.5. `FLASH_UPDATE` is the only path that launches a
/// provisional image: on a normal boot an unbought TBYB image is not the
/// current image, and the ROM boots the other slot instead.
const REBOOT_NORMAL: u32 = 0x0;
const REBOOT_FLASH_UPDATE: u32 = 0x4;
const REBOOT_NO_RETURN: u32 = 0x100;

/// Where `partimg ab` puts image B: sector 17, as an XIP address and as a raw
/// flash offset. `reboot(FLASH_UPDATE)` takes an `update_base`, and which of
/// the two it wants is the thing this experiment finds out — so A tries the
/// XIP address first and the storage offset second, and prints what came back.
const B_BASE_XIP: u32 = 0x1001_1000;
const B_BASE_STORAGE: u32 = 0x0001_1000;

/// `PT_INFO`, from `get_partition_table_info` (§5.5.11.2).
const PT_INFO: u32 = 0x0001;

/// **Slot A's entire authority over what this board will run**, and it is 65
/// bytes of ordinary flash. Identical in role to
/// [exp166](../exp166-whose-firmware-will-it-accept/)'s, and carrying the same
/// ceiling: anybody who can write flash can replace *this image*, and then the
/// board accepts whatever they like. The signature governs the **update path**,
/// not the bench.
///
/// The matching private key is a test key, published in this experiment's
/// README, and is never on the board.
const TRUSTED_KEY: [u8; 65] = [
    0x04, 0x61, 0x78, 0x88, 0x17, 0xa1, 0x41, 0x90, 0x3f, 0xb9, 0xac, 0x46, 0xab, 0x03, 0xfb, 0xde,
    0x47, 0x18, 0x12, 0x62, 0xad, 0x41, 0x0b, 0x69, 0x09, 0x88, 0xa0, 0xb9, 0xd1, 0x67, 0xce, 0xcd,
    0xee, 0xed, 0x2d, 0x1f, 0x96, 0xde, 0xfb, 0x9c, 0x84, 0x43, 0xfe, 0x1d, 0x56, 0x9e, 0xf5, 0x59,
    0xa6, 0xc4, 0xba, 0xcb, 0x8c, 0x35, 0x9a, 0x10, 0x57, 0x9b, 0x12, 0x0a, 0x63, 0xf0, 0x9a, 0xad,
    0xb0,
];

const XIP_BASE: u32 = 0x1000_0000;

/// One QMI address-translation aperture covers this much virtual space. Eight
/// of them tile the XIP window, and the aperture a virtual address falls in is
/// its offset divided by this.
const APERTURE: u32 = 0x0040_0000;

/// Where the whole flash is identity-mapped, as an offset from [`XIP_BASE`].
///
/// **Measured, not chosen.** `ATRANS4`-`ATRANS7` come back `base = 0x0, 0x400,
/// 0x800, 0xc00` with `size = 0x400` each: four consecutive apertures that tile
/// all 16 MiB of flash at its own address. So slot B, which lives at physical
/// `0x11000`, is readable here - and *not* at `0x11000` itself, which is past
/// the end of the 64 KiB aperture the ROM gives a running image onto its own
/// partition.
const IDENTITY: u32 = 4 * APERTURE;

/// Is this range something the chip will actually answer?
///
/// **The guard this experiment was wedged into existing.** The datasheet says
/// of an aperture's `SIZE` field:
///
/// > Offsets greater than SIZE return a bus error, and do not cause a QSPI
/// > access.
///
/// A bus error is a HardFault; `panic-halt` stops the core; a stopped core
/// answers no control requests, so the board stays enumerated, never logs, and
/// cannot be reached by the 1200-baud reflash touch. The first build of this
/// firmware read `0x10011000` - sector 17, one sector past `ATRANS0`'s
/// 16-sector aperture - and cost a hand on the BOOTSEL button.
///
/// So the aperture is **read** and the arithmetic done before any address is
/// dereferenced. A range that would fault is refused, in words, by a board that
/// is still talking.
fn addressable(offset: u32, len: u32) -> Result<(), Refusal> {
    let end = offset.checked_add(len).ok_or(Refusal::RegionOutOfRange)?;
    let first = offset / APERTURE;
    // A range that crosses an aperture boundary would need two checks and has
    // no use here, so it is refused rather than half-checked.
    if end == 0 || (end - 1) / APERTURE != first || first >= 8 {
        return Err(Refusal::RegionOutOfRange);
    }
    let size_bytes = embassy_rp::pac::QMI.atrans(first as usize).read().size() as u32 * 4096;
    if (offset % APERTURE) + len > size_bytes {
        return Err(Refusal::RegionOutOfRange);
    }
    Ok(())
}

/// `[cmd:1][offset:4 LE][len:4 LE][signature:64]` — byte for byte
/// [exp166](../exp166-whose-firmware-will-it-accept/)'s frame, so the host half
/// is the same shape and a reader who has seen one has seen both.
const FRAME_LEN: usize = 73;
const CMD_VERIFY: u8 = 1;

/// Set by the verifier when, and only when, a signature over slot B checked out
/// against [`TRUSTED_KEY`]. Slot A polls it; nothing else starts a trial.
static GO: AtomicBool = AtomicBool::new(false);
/// How many frames arrived, and how they came out. Printed by the idle loop, so
/// a board that was never asked anything is distinguishable from one that was
/// asked and said no — which is the distinction this whole experiment is about.
static ASKED: AtomicU32 = AtomicU32::new(0);
static REFUSED: AtomicU32 = AtomicU32::new(0);

struct Hex<'a>(&'a [u8]);

impl core::fmt::Display for Hex<'_> {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        for b in self.0 {
            write!(f, "{:02x}", b)?;
        }
        Ok(())
    }
}

/// Why a request was not accepted. Plumbing and cryptography are named apart
/// because a reader who cannot tell them apart blames the wrong layer —
/// [exp136](../exp136-joining-halfway/)'s concern, arriving as a logging rule.
#[derive(Copy, Clone)]
enum Refusal {
    ShortFrame(usize),
    UnknownCommand(u8),
    RegionOutOfRange,
    EmptyRegion,
    MalformedSignature,
    BadKey,
    SignatureDoesNotVerify,
}

impl core::fmt::Display for Refusal {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Refusal::ShortFrame(n) => write!(f, "the frame is {} bytes, not {}", n, FRAME_LEN),
            Refusal::UnknownCommand(c) => write!(f, "unknown command byte {:#04x}", c),
            Refusal::RegionOutOfRange => write!(f, "the region leaves the window this image reads"),
            Refusal::EmptyRegion => write!(f, "the region is empty"),
            Refusal::MalformedSignature => write!(f, "the 64 bytes are not a P-256 signature"),
            Refusal::BadKey => write!(f, "the compiled-in public key does not parse"),
            Refusal::SignatureDoesNotVerify => {
                write!(f, "the signature is not this key's, over these bytes")
            }
        }
    }
}

impl Refusal {
    fn layer(self) -> &'static str {
        match self {
            Refusal::SignatureDoesNotVerify | Refusal::MalformedSignature | Refusal::BadKey => {
                "cryptography"
            }
            _ => "plumbing",
        }
    }
}

/// The named bytes, as a slice of execute-in-place flash.
///
/// **This is the measurement candidate 1 is for.** The ROM remaps whichever
/// partition it booted to `0x10000000` ([exp142](../exp142-two-images-one-version/)),
/// and whether the *other* slot is still readable at its own XIP offset while
/// that remap is active is a thing no experiment here had established. It is
/// read rather than assumed, and the digest is printed so a host can say
/// whether these are the bytes it signed.
fn region(offset: u32, len: u32) -> Result<&'static [u8], Refusal> {
    if len == 0 {
        return Err(Refusal::EmptyRegion);
    }
    addressable(offset, len)?;
    Ok(unsafe { core::slice::from_raw_parts((XIP_BASE + offset) as *const u8, len as usize) })
}

/// Hash the named region and check the signature over it. Returns the digest
/// either way, because a verifier that reports only pass or fail can be trusted
/// and cannot be checked.
fn check(frame: &[u8]) -> (Option<[u8; 32]>, Result<(), Refusal>) {
    if frame.len() != FRAME_LEN {
        return (None, Err(Refusal::ShortFrame(frame.len())));
    }
    if frame[0] != CMD_VERIFY {
        return (None, Err(Refusal::UnknownCommand(frame[0])));
    }
    let offset = u32::from_le_bytes([frame[1], frame[2], frame[3], frame[4]]);
    let len = u32::from_le_bytes([frame[5], frame[6], frame[7], frame[8]]);
    let bytes = match region(offset, len) {
        Ok(b) => b,
        Err(e) => return (None, Err(e)),
    };
    let mut h = Sha256::new();
    h.update(bytes);
    let digest: [u8; 32] = h.finalize().into();
    let outcome = (|| {
        let vk = VerifyingKey::from_sec1_bytes(&TRUSTED_KEY).map_err(|_| Refusal::BadKey)?;
        let sig = Signature::from_slice(&frame[9..]).map_err(|_| Refusal::MalformedSignature)?;
        vk.verify(bytes, &sig).map_err(|_| Refusal::SignatureDoesNotVerify)
    })();
    (Some(digest), outcome)
}

/// How far slot A has got, in LED blinks. Every stage is set immediately
/// *before* the thing it names is attempted, so the number that keeps blinking
/// is the step that did not come back — [`breadcrumb`](../../crates/breadcrumb/)'s
/// idea, without the reboot, because this failure did not reboot.
///
///  1  the executor is running and tasks are being scheduled
///  2  USB built, tasks spawned
///  3  slot A settled and is about to read its own IMAGE_DEF and watchdog
///  4  about to read slot B through XIP  <- the read nobody had established
///  5  about to hash slot B's first 4 KiB
///  6  waiting for a signature; everything before this worked
///  7  a signature verified; about to ask the ROM for a flash update boot
static STAGE: AtomicU32 = AtomicU32::new(1);

/// Slot B as an offset from the XIP base, which is what a frame names and what
/// [`region`] adds `XIP_BASE` back to. The same sector 17 `B_BASE_XIP` points
/// at, written once so the two cannot drift apart.
/// Slot B's place in flash, which is not a place this image can address.
const B_FLASH_OFFSET: u32 = B_BASE_XIP - XIP_BASE;

/// What each probe is for. Nothing here is graded: the map is the thing the
/// experiment was written to find out, and an expected answer in a table is an
/// answer the run cannot contradict — exp162's lesson, and exp164 needed it
/// twice.
struct Probe {
    offset: u32,
    what: &'static str,
}
const PROBES: [Probe; 5] = [
    Probe { offset: 0x0000_0000, what: "aperture 0, first sector" },
    Probe { offset: 0x0000_f000, what: "aperture 0, last sector" },
    Probe { offset: 0x0001_0000, what: "one sector past aperture 0" },
    Probe { offset: 0x0001_1000, what: "slot B, where it lives" },
    Probe { offset: IDENTITY + 0x0001_1000, what: "the same, via aperture 4" },
];

/// Scratch space for `explicit_buy`: it rewrites a flash sector to clear the
/// TBYB bit, and the sector it is rewriting is the one this code was booted
/// from, so the ROM needs somewhere in RAM to hold it. 4 KiB, 4 KiB-aligned,
/// as §5.5.12.3 requires.
#[repr(C, align(4096))]
struct Scratch([u8; 4096]);
static mut BUY_SCRATCH: Scratch = Scratch([0; 4096]);

/// The watchdog block, by hand (§12.9). `embassy-rp` keeps its PAC private and
/// its own `Watchdog` driver only starts and feeds one — this experiment needs
/// to *read* a watchdog somebody else armed, without disturbing it, so the four
/// registers are named here and touched with volatile accesses.
mod watchdog_regs {
    pub const BASE: usize = 0x400d_8000;
    /// CTRL: TIME in bits 23:0 (microseconds), ENABLE at bit 30.
    pub const CTRL: usize = BASE;
    /// LOAD: write to reload the countdown. Max 0xffffff — about 16 seconds.
    pub const LOAD: usize = BASE + 0x04;
    /// REASON: bit 0 TIMER — the last reset was a watchdog timeout.
    pub const REASON: usize = BASE + 0x08;

    pub const CTRL_TIME_MASK: u32 = 0x00ff_ffff;
    pub const CTRL_ENABLE: u32 = 1 << 30;
    pub const REASON_TIMER: u32 = 1 << 0;

    pub fn read(addr: usize) -> u32 {
        unsafe { core::ptr::read_volatile(addr as *const u32) }
    }
    pub fn write(addr: usize, value: u32) {
        unsafe { core::ptr::write_volatile(addr as *mut u32, value) }
    }
}

/// The watchdog exactly as the boot ROM left it, read before anything else
/// runs. If the ROM arms a trial clock for a provisional image, this is where
/// it shows: `enable` set, and `time` counting down.
#[derive(Clone, Copy)]
struct Watchdog {
    enabled: bool,
    /// CTRL.TIME — what is left of the countdown, in microseconds.
    time_us: u32,
    /// LOAD — what the countdown is reloaded to.
    load_us: u32,
    /// REASON.TIMER — was the reset that started this boot a watchdog timeout?
    last_reset_was_timeout: bool,
}

impl Watchdog {
    /// Read it, do not touch it. Called first thing in `main`, before
    /// `embassy_rp::init`, so nothing of ours can be blamed for the numbers.
    fn capture() -> Self {
        use watchdog_regs as wr;
        let ctrl = wr::read(wr::CTRL);
        Self {
            enabled: ctrl & wr::CTRL_ENABLE != 0,
            time_us: ctrl & wr::CTRL_TIME_MASK,
            load_us: wr::read(wr::LOAD) & wr::CTRL_TIME_MASK,
            last_reset_was_timeout: wr::read(wr::REASON) & wr::REASON_TIMER != 0,
        }
    }

    /// Stop it. Only ever called after a buy has been confirmed in flash — a
    /// bought image that let the trial clock run out would be reset for winning.
    fn disable() {
        use watchdog_regs as wr;
        wr::write(wr::CTRL, wr::read(wr::CTRL) & !wr::CTRL_ENABLE);
    }
}

/// This image's IMAGE_TYPE word **as it is in flash right now**.
///
/// `Block` is `#[repr(C)]`: the start marker, then the items. So the first item
/// — the image type — is one word in. Volatile, because the point is to see a
/// change the compiler has no way to know about.
fn image_type_in_flash() -> u32 {
    let p = core::ptr::addr_of!(IMAGE_DEF) as *const u32;
    unsafe { core::ptr::read_volatile(p.add(1)) }
}

fn is_provisional(image_type_word: u32) -> bool {
    (image_type_word >> 16) as u16 & IMAGE_TYPE_TBYB != 0
}

#[embassy_executor::task]
async fn usb_task(mut device: UsbDevice<'static, Driver<'static, USB>>) -> ! {
    device.run().await
}

#[embassy_executor::task]
async fn log_task(sender: Sender<'static, usb_reboot::UsbDriver>) -> ! {
    usb_log::run(sender).await
}

/// The 1200-baud watcher, so the next flash needs no button — and the gate.
///
/// exp143's version of this task treated *any* byte from the host as a brake.
/// This one treats a **valid signature over slot B** as the only accelerator,
/// which is the difference between the two experiments in one function: there
/// is no timeout that starts a trial, and no byte that starts one either.
#[embassy_executor::task]
async fn control_task(
    control: ControlChanged<'static>,
    mut receiver: Receiver<'static, usb_reboot::UsbDriver>,
) -> ! {
    let mut buf = [0u8; PACKET];
    // `joined`, not `fresh`: this image can never know it is reading the host's
    // stream from its first byte. exp166 has the argument.
    let mut frames = cobs::Deframer::joined();
    loop {
        match select(control.control_changed(), receiver.read_packet(&mut buf)).await {
            Either::First(()) => {
                let rate = receiver.line_coding().data_rate();
                usb_reboot::reboot_if_requested(rate).await;
            }
            Either::Second(Ok(n)) if n > 0 => {
                for &byte in &buf[..n] {
                    let Some(len) = frames.feed(byte) else { continue };
                    // A zero-length frame is not a message: senders lead with a
                    // delimiter, which closes an empty frame behind the previous
                    // one once the decoder is synchronised. exp166 counted to
                    // eleven for five requests before this line existed.
                    if len == 0 {
                        continue;
                    }
                    let frame = &frames.payload()[..len];
                    let asked = ASKED.fetch_add(1, Ordering::Relaxed) + 1;
                    log!("--- request #{}: {} byte frame", asked, len);
                    Timer::after(PACE).await;
                    if len >= 9 {
                        log!(
                            "  region: offset={:#x} len={} ({:#010x}..)",
                            u32::from_le_bytes([frame[1], frame[2], frame[3], frame[4]]),
                            u32::from_le_bytes([frame[5], frame[6], frame[7], frame[8]]),
                            XIP_BASE + u32::from_le_bytes([frame[1], frame[2], frame[3], frame[4]])
                        );
                        Timer::after(PACE).await;
                    }
                    let (digest, outcome) = check(frame);
                    if let Some(d) = digest {
                        log!("  sha256 = {}", Hex(&d));
                        Timer::after(PACE).await;
                    }
                    match outcome {
                        Ok(()) => {
                            log!("  ACCEPTED: slot B is signed by the key this image trusts");
                            Timer::after(PACE).await;
                            log!("  starting the trial.");
                            GO.store(true, Ordering::Relaxed);
                        }
                        Err(r) => {
                            REFUSED.fetch_add(1, Ordering::Relaxed);
                            log!("  REFUSED ({}): {}", r.layer(), r);
                            Timer::after(PACE).await;
                            log!("  no trial. Slot B will not run.");
                        }
                    }
                    Timer::after(PACE).await;
                }
            }
            Either::Second(_) => {}
        }
    }
}

/// Print the state the ROM handed this boot: how it got here, and whether a
/// trial clock is running.
async fn report_boot(wd: Watchdog, image_type: u32) {
    // Two lines, not one: usb_log cuts at 96 bytes and marks the cut with `...`,
    // and a truncated hex word is not evidence of anything.
    log!("I am slot {}, version {}.{}.", SLOT, VERSION_MAJOR, VERSION_MINOR);
    Timer::after(PACE).await;
    log!(
        "IMAGE_TYPE in flash = {:#010x} — TBYB {}",
        image_type,
        if is_provisional(image_type) { "set (provisional)" } else { "clear (permanent)" }
    );
    log!(
        "watchdog as the ROM left it: enable={}, time={} us, load={} us",
        wd.enabled,
        wd.time_us,
        wd.load_us
    );
    Timer::after(PACE).await;
    // REASON.TIMER, said plainly and not over-read. Measured on hardware: it is
    // set after an ordinary `pflash` too, because the ROM's own reboot path goes
    // through the watchdog. So this bit says "a watchdog reset started this
    // boot", and never "a trial ran out" — the two are not distinguishable here.
    log!(
        "WATCHDOG.REASON.TIMER = {} (a watchdog reset started this boot; the ROM's",
        wd.last_reset_was_timeout as u8
    );
    log!("  own reboot uses the watchdog too, so this alone proves nothing about a trial)");
    Timer::after(PACE).await;
}

/// Slot A: the image that is already bought. It says where it stands, then
/// hands the board to the provisional image on purpose.
#[embassy_executor::task]
async fn permanent_task(wd: Watchdog) -> ! {
    Timer::after(SETTLE).await;
    STAGE.store(3, Ordering::Relaxed);
    report_boot(wd, image_type_in_flash()).await;

    let mut buf = [0u32; 16];
    let n = unsafe { rom_data::get_partition_table_info(buf.as_mut_ptr(), buf.len(), PT_INFO) };
    log!("get_partition_table_info(PT_INFO) -> {}", n);
    Timer::after(PACE).await;
    let b = unsafe { rom_data::get_b_partition(0) };
    log!("get_b_partition(0) -> {} (1 = there is a B side to try)", b);
    Timer::after(PACE).await;

    if !TBYB {
        // **Candidate 1, and it is the measurement the design rests on.** The
        // ROM remapped this partition to 0x10000000; whether the other slot is
        // still readable at its own XIP offset is not something any experiment
        // here had established. Sixteen bytes and a digest over the first
        // sector, printed before anybody asks for anything.
        // **The eight apertures, and the reason the first build of this
        // experiment wedged a board.** The ROM does not give a running image
        // the whole flash: QMI translates a virtual XIP address through one of
        // eight apertures, each with a base and a *size*, and the datasheet is
        // explicit about what lies past the end of one —
        //
        //   > Offsets greater than SIZE return a bus error, and do not cause a
        //   > QSPI access.
        //
        // A bus error is a HardFault, `panic-halt` stops the core, and a core
        // that has stopped answers no control requests: the board stays
        // enumerated, the log never emits a byte, and the 1200-baud reflash
        // touch cannot get in. That is not a hang to be debugged. It is a
        // documented refusal, and this is where it is read instead of walked
        // into.
        for i in 0..8 {
            let a = embassy_rp::pac::QMI.atrans(i).read();
            let (base, size) = (a.base() as u32, a.size() as u32);
            log!(
                "  ATRANS{}: base={:#x} size={:#x} -> phys {:#08x}..{:#08x}, {} KiB",
                i,
                base,
                size,
                base * 4096,
                base * 4096 + size * 4096,
                size * 4
            );
            Timer::after(PACE).await;
        }
        log!("  a read past an aperture's SIZE is a bus error, not a wrong answer.");
        Timer::after(PACE).await;

        // **Five probes, and the guard answers all of them without dereferencing
        // anything it has not proved is backed.** Two are inside the window the
        // ROM gave this image, two are past its end — including slot B — and
        // one is in the apertures that map a second chip select this board does
        // not have.
        for pr in PROBES.iter() {
            match region(pr.offset, 0x1000) {
                Ok(b) => {
                    let mut h = Sha256::new();
                    h.update(b);
                    let d: [u8; 32] = h.finalize().into();
                    log!("  {:<26} {:#09x} READ  {}", pr.what, pr.offset, Hex(&d[..12]));
                }
                Err(e) => log!("  {:<26} {:#09x} REFUSED: {}", pr.what, pr.offset, e),
            }
            Timer::after(PACE).await;
        }
        log!("  slot B is at flash offset {:#x}, and nothing here can read it.", B_FLASH_OFFSET);
        Timer::after(PACE).await;

        log!("the trusted key is {} bytes at {:#010x}.", TRUSTED_KEY.len(), TRUSTED_KEY.as_ptr() as u32);
        Timer::after(PACE).await;
        log!("waiting for a signature over slot B. There is no timeout: an image");
        Timer::after(PACE).await;
        log!("nobody signed is an image that never runs.");
        STAGE.store(6, Ordering::Relaxed);

        // No `TRY_AFTER`, and that absence is the experiment. exp143 handed the
        // board over on a clock; this one hands it over on a signature, and on
        // nothing else.
        loop {
            Timer::after(Duration::from_millis(200)).await;
            if !GO.load(Ordering::Relaxed) {
                continue;
            }
            // A flash update boot is the only way in: on a normal boot the ROM
            // will not run an unbought TBYB image. If this call works, nothing
            // below it ever runs.
            STAGE.store(7, Ordering::Relaxed);
            log!("reboot(FLASH_UPDATE, update_base={:#010x}) — see you on the other side", B_BASE_XIP);
            Timer::after(PACE).await;
            let rc = rom_data::reboot(REBOOT_FLASH_UPDATE | REBOOT_NO_RETURN, 50, B_BASE_XIP, 0);
            log!("it came back: rc={} — the XIP address is not what update_base means", rc);
            Timer::after(PACE).await;
            let rc = rom_data::reboot(REBOOT_FLASH_UPDATE | REBOOT_NO_RETURN, 50, B_BASE_STORAGE, 0);
            log!("the storage offset came back too: rc={}. No trial was started.", rc);
            GO.store(false, Ordering::Relaxed);
        }
    }

    loop {
        Timer::after(IDLE_REPORT).await;
        let w = image_type_in_flash();
        log!(
            "idle: slot {} v{}.{} — IMAGE_TYPE {:#010x}, TBYB {}",
            SLOT,
            VERSION_MAJOR,
            VERSION_MINOR,
            w,
            if is_provisional(w) { "set" } else { "clear" }
        );
    }
}

/// Slot B: the provisional image. It is here on trial, and the whole question
/// is whether it calls `explicit_buy` before the ROM's clock runs out.
#[embassy_executor::task]
async fn provisional_task(wd: Watchdog) -> ! {
    Timer::after(SETTLE).await;
    let before = image_type_in_flash();
    report_boot(wd, before).await;

    if !is_provisional(before) {
        log!("nothing to buy: the TBYB bit is already clear, so this image was");
        log!("bought in an earlier boot and the ROM started it the ordinary way.");
        log!("A bought image is just an image.");
    } else {
        log!("this is a trial boot, and the clock above is the trial. Deciding in {} s.", TRIAL_TALK.as_secs());
        Timer::after(TRIAL_TALK).await;

        // A second sample. One reading of CTRL.TIME is a number; two readings
        // that differ are a clock, and a clock is what makes this a trial.
        let now = Watchdog::capture();
        log!(
            "watchdog now: enable={}, time={} us ({} us gone since boot)",
            now.enabled,
            now.time_us,
            wd.time_us.saturating_sub(now.time_us)
        );

        if BUY {
            log!("calling explicit_buy — it rewrites the sector I am running from");
            // Interrupts off: the ROM erases and reprograms flash under XIP, and
            // an interrupt handler fetched from that flash while it is erased is
            // the classic way to lose the board. The cost of getting this wrong
            // is a crash, which is a trial that ends without a buy — the safe
            // side of this experiment.
            let rc = cortex_m::interrupt::free(|_| unsafe {
                rom_data::explicit_buy(core::ptr::addr_of_mut!(BUY_SCRATCH) as *mut u8, 4096)
            });
            unsafe { rom_data::flash_flush_cache() };
            let after = image_type_in_flash();
            log!("explicit_buy -> {}", rc);
            log!(
                "IMAGE_TYPE in flash is now {:#010x} — TBYB {}",
                after,
                if is_provisional(after) { "STILL SET (not bought)" } else { "CLEARED (bought)" }
            );
            let post = Watchdog::capture();
            log!("watchdog after the buy: enable={}, time={} us", post.enabled, post.time_us);
            if !is_provisional(after) {
                // Bought. If the ROM left its trial clock running, stop it, or
                // this image gets reset for winning.
                if post.enabled && post.time_us > 0 {
                    Watchdog::disable();
                    log!("trial clock was still running after the buy — stopped it");
                }
                log!("bought. This slot is now the one a plain reset boots — and here is");
                log!("the proof, in {} s: a plain reset, and see who comes back.", PROVE_AFTER.as_secs());
                Timer::after(PROVE_AFTER).await;
                // Exactly once: the next boot finds TBYB clear and takes the
                // "nothing to buy" branch, so it does not reset again.
                rom_data::reboot(REBOOT_NORMAL | REBOOT_NO_RETURN, 50, 0, 0);
            }
        } else {
            log!("not buying. Nothing is wrong with me — I simply never call it.");
            log!("From here the ROM takes the board back to the other slot.");
            if !now.enabled || now.time_us == 0 {
                // No trial clock is running, so nothing will end this boot.
                // End it honestly: a plain reset, with the buy never made.
                log!("no trial clock is running, so: reboot(NORMAL), unbought.");
                Timer::after(Duration::from_secs(2)).await;
                rom_data::reboot(REBOOT_NORMAL | REBOOT_NO_RETURN, 50, 0, 0);
            }
        }
    }

    // The repeating line carries the state, read from flash each time. The lines
    // said at boot are gone within a minute — usb_log's queue is sixteen deep —
    // so a reader who arrives late, or a check.sh that runs against a board that
    // has been up for an hour, has to be able to learn this from a line that
    // keeps coming. And it is read from flash, not from the build flag, for the
    // same reason as the product string.
    loop {
        Timer::after(IDLE_REPORT).await;
        let w = image_type_in_flash();
        log!(
            "idle: slot {} v{}.{} — IMAGE_TYPE {:#010x}, TBYB {}",
            SLOT,
            VERSION_MAJOR,
            VERSION_MINOR,
            w,
            if is_provisional(w) { "set (unbought)" } else { "clear (bought)" }
        );
    }
}

#[embassy_executor::task]
async fn blink_task(mut led: Output<'static>) -> ! {
    loop {
        // **The LED counts how far slot A got**, and that is not decoration.
        // The first build of this experiment enumerated on USB and never
        // logged a byte: the port opened, DTR was asserted, and fifteen seconds
        // produced nothing. With the log silent there was no way to tell a
        // firmware that stopped at the first line from one that stopped at the
        // last, and the board had to be recovered with the button.
        //
        // `docs/debugging-without-a-board.md` says the LED is the only channel
        // left when firmware fails, and says to prove it works before you need
        // it. This is that channel: N blinks, a pause, repeat.
        let n = STAGE.load(Ordering::Relaxed).max(1);
        for _ in 0..n {
            led.set_high();
            Timer::after(BLINK_ON).await;
            led.set_low();
            Timer::after(Duration::from_millis(200)).await;
        }
        Timer::after(BLINK_OFF).await;
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    // First, before anything of ours can disturb it: what did the ROM leave in
    // the watchdog?
    let wd = Watchdog::capture();

    let p = embassy_rp::init(Default::default());
    let led = Output::new(p.PIN_25, Level::Low);
    let driver = Driver::new(p.USB, Irqs);

    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    // The slot is in the product string, so which image is running is visible
    // from `yi26 port` alone — the log needs an open port, and a trial image
    // may not be there long enough to wait for one.
    //
    // "provisional" comes from the **flash**, not from the build flag: after a
    // buy the same binary is no longer provisional, and a descriptor that still
    // said so would be the one place in this experiment that lied.
    config.product = Some(match (SLOT, is_provisional(image_type_in_flash())) {
        ("A", _) => "exp167 slot A",
        ("B", true) => "exp167 slot B provisional",
        _ => "exp167 slot B bought",
    });
    config.serial_number = Some("167");
    config.device_class = 0xef;
    config.device_sub_class = 0x02;
    config.device_protocol = 0x01;
    config.composite_with_iads = true;

    static CONFIG_DESCRIPTOR: StaticCell<[u8; 256]> = StaticCell::new();
    static BOS_DESCRIPTOR: StaticCell<[u8; 256]> = StaticCell::new();
    static CONTROL_BUF: StaticCell<[u8; 64]> = StaticCell::new();
    static ACM_STATE: StaticCell<State> = StaticCell::new();

    let mut builder = Builder::new(
        driver,
        config,
        CONFIG_DESCRIPTOR.init([0; 256]),
        BOS_DESCRIPTOR.init([0; 256]),
        &mut [],
        CONTROL_BUF.init([0; 64]),
    );

    let class = CdcAcmClass::new(&mut builder, ACM_STATE.init(State::new()), PACKET as u16);
    let usb = builder.build();
    spawner.spawn(usb_task(usb).unwrap());

    let (sender, receiver, control) = class.split_with_control();
    spawner.spawn(log_task(sender).unwrap());
    spawner.spawn(control_task(control, receiver).unwrap());
    if TBYB {
        spawner.spawn(provisional_task(wd).unwrap());
    } else {
        spawner.spawn(permanent_task(wd).unwrap());
    }
    spawner.spawn(blink_task(led).unwrap());
    STAGE.store(2, Ordering::Relaxed);

    log!(
        "exp167 up. slot {} v{}.{}, {}.",
        SLOT,
        VERSION_MAJOR,
        VERSION_MINOR,
        // From flash again, for the same reason as the product string above.
        if is_provisional(image_type_in_flash()) { "provisional (TBYB)" } else { "permanent" }
    );
}
