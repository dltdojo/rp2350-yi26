//! exp160 — a secret too big to hide.
//!
//! The fourth experiment on the [signing road](../README.md#the-signing-road).
//! [exp159](../exp159-a-key-that-was-never-in-flash/) put a P-256 key in a bank
//! Non-secure code cannot read and had it sign something. The road said the next
//! step was to swap the crate for ML-DSA-65 and find out whether a
//! post-quantum signature still fits. So this is exp159's matrix with one
//! dependency line changed, plus **one candidate that exp159 did not need**.
//!
//! # The claim
//!
//! > **exp159's wall does not survive the swap. It still refuses every read of
//! > bank 8 — and the key is readable by Non-secure code anyway, because
//! > producing one ML-DSA-65 signature leaves copies of the seed in ordinary,
//! > open SRAM that no ACCESSCTRL register covers.**
//!
//! # What was measured before any of this was designed
//!
//! Six facts, on 2026-08-21, none of them assumed. Four changed the design.
//!
//! | fact | how | what it changed |
//! | --- | --- | --- |
//! | `ml-dsa` 0.1.1 builds no_std for this target on **stable** | compiled it | no nightly, no veneer |
//! | ML-DSA-65 costs **16,380 bytes of `.text`**; P-256 costs **20,356** against the same empty baseline | built both | ← **the post-quantum signature is the smaller code.** The road expected the opposite |
//! | the private key **is a 32-byte seed**, and `sign_deterministic` needs no RNG | read `signing.rs`, ran it | ← the seed fits bank 8 with 4,064 bytes to spare |
//! | `SigningKey<MlDsa65>` is **65,696 bytes** in memory | `size_of` | ← **160 bytes larger than one 64 KB SRAM bank**, which is the biggest thing ACCESSCTRL can gate |
//! | one signature's stack frame is **188,116 bytes** in this build (277,308 in a bare spike) | read the prologue with `llvm-objdump` | ← a third of the chip's RAM, all of it in the open region, and enough that the exact figure has to be measured rather than quoted |
//! | after the `SigningKey` is dropped, **copies of the seed remain in the dead frame** | ran it on a host and swept the frame | ← candidate 5 exists, and it is not built on a guess |
//! | the crate's `zeroize` feature is **off by default** and turning it on does **not** remove that copy | built both ways on a host and swept | ← added 2026-08-21. `Drop` zeroes an object; this is scratch no object owns. See C2a in the README |
//!
//! # Three contradictions
//!
//! ## 1. exp159's wall holds 4 KB. This secret's working form is 65,696 bytes.
//!
//! `ACCESSCTRL` gates ten SRAM banks: eight of 64 KB and two of 4 KB. The
//! **finest** thing it can protect is 4 KB and the **largest** is 64 KB. An
//! ML-DSA-65 signing key in the form the arithmetic needs is 65,696 bytes, so
//! there is no single bank on this part that could hold one.
//!
//! The seed is 32 bytes, so bank 8 still works — for the seed. What it cannot
//! hold is what the seed turns into the moment it is used.
//!
//! ## 2. The naive port passes the matrix, and the pass is hollow.
//!
//! This is the one worth stopping on, and it is the third time this road has met
//! it. Candidate 4 — *bank 8 shut, Non-secure asks, 3,309 bytes come back* —
//! **passes**. It would have been reported as a success. Meanwhile the signing
//! ran on core 0's ordinary stack, in the main 512 KB, which defaults to fully
//! open access and is the same region core 1's own stack lives in.
//!
//! > exp159's own idea to take away was *a boundary is only as good as the worst
//! > place the secret lives*, and it was written about flash. Here the worst
//! > place is not somewhere the author put the key. **It is somewhere the
//! > library put it**, in memory that exists for a few milliseconds and is never
//! > cleaned up.
//!
//! So candidate 5 goes looking for it, and the sweep is honest because the
//! region is **painted with `0xC5` before the signature is made**: anything
//! found afterwards was put there by this signature and by nothing else.
//!
//! ## 3. A 3,309-byte signature does not fit the way this repository reports.
//!
//! `usb-log` truncates at 96 bytes per line and drops the newest line when its
//! 16-deep queue fills. exp159's entire proof was five lines. exp160's public
//! key and signature are 165 of the report block's **173** lines, emitted 32
//! bytes at a time with an index, paced so the queue never overflows. That is
//! not a workaround; it is one of the costs the road was asking about.
//!
//! # The matrix
//!
//! ```text
//!   1  Secure core 0 makes one ML-DSA-65 signature       it fits at all  (control)
//!   2  Non-secure core 1 reads bank 8, allowed           must work       (control)
//!   3  Non-secure core 1 reads bank 8, DENIED            must be refused
//!   4  Non-secure asks for a signature, bank 8 shut      3,309 bytes back
//!   5  Secure sweeps the stack it just signed on,
//!      and Non-secure reads what it finds                ← the finding
//! ```
//!
//! Candidate 1 is a control in a way exp159's was not: 188 KB of stack frame is
//! a third of this chip, so *does one signature fit alongside the harness at all*
//! is a real question, and if the answer is no the breadcrumb says which
//! candidate died rather than leaving a dark board.
//!
//! # What is deliberately not done
//!
//! Nothing writes `ACCESSCTRL.LOCK`, nothing writes a key to flash, and the
//! seed is generated on the board from the TRNG. `KAT_SEED` is all zeros, is
//! **public**, never enters bank 8 and never signs anything: it exists so the
//! board can print a public key whose correct value is known independently of
//! this firmware and of the crate it uses.

#![no_std]
#![no_main]

use core::sync::atomic::{AtomicBool, AtomicU32, Ordering};

use cortex_m_rt::{exception, ExceptionFrame};
use embassy_executor::Spawner;
use embassy_rp::bind_interrupts;
use embassy_rp::gpio::{Level, Output};
use embassy_rp::multicore::{spawn_core1, Stack};
use embassy_rp::peripherals::{TRNG, USB};
use embassy_rp::trng::Trng;
use embassy_rp::usb::{Driver, InterruptHandler};
use embassy_time::{Duration, Instant, Timer};
use embassy_usb::class::cdc_acm::{CdcAcmClass, ControlChanged, Receiver, Sender, State};
use embassy_usb::{Builder, Config as UsbConfig, UsbDevice};
use hybrid_array::Array;
use ml_dsa::{MlDsa65, Seed, SigningKey};
use panic_halt as _;
use rp2350_linker as _;
use static_cell::StaticCell;
use usb_log::log;

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
    TRNG_IRQ => embassy_rp::trng::InterruptHandler<TRNG>;
});

/// SRAM bank 8: 4 KB of its own, immediately above the main 512 KB. Not in
/// `rp2350-linker`'s memory map, so nothing the linker places can land here.
const KEYSTORE: usize = 0x2008_0000;

/// Which `ACCESSCTRL.SRAM[n]` register gates [`KEYSTORE`]. Assumed, and
/// candidate 3 checks the assumption: a wrong register means no refusal, and
/// the run says so instead of passing quietly.
const KEYSTORE_BANK: usize = 8;

/// Deliberately **not** exp159's `0x4B455931`. Bank 8 survives a watchdog reset
/// and it survives a reflash, so a board that ran exp159 an hour ago still has
/// exp159's key sitting there. A different magic means this firmware never
/// mistakes that key for its own.
const KEY_MAGIC: u32 = 0x4B45_5932;

/// NSU (bit 0) and NSP (bit 1) — the two bits that are the wall. Field order
/// established from silicon by exp156.
const NON_SECURE_BITS: u32 = 0b11;

const SEED_LEN: usize = 32;
const PK_LEN: usize = 1952;
const SIG_LEN: usize = 3309;

const C_SECURE_SIGN: u8 = 1;
const C_NS_READ_ALLOWED: u8 = 2;
const C_NS_READ_DENIED: u8 = 3;
const C_NS_SIGN: u8 = 4;
const C_NS_FINDS_COPY: u8 = 5;
const CANDIDATES: u8 = 5;

/// Generous on purpose. One ML-DSA-65 signature had never been timed on this
/// part when this was written, and candidate 5 also paints and sweeps several
/// hundred kilobytes. A budget shorter than a step that was going to succeed
/// reports a death that never happened. The watchdog's own ceiling is
/// `0x00ff_ffff` µs, so this is close to the largest budget there is.
const STEP_BUDGET_US: u32 = 15_000_000;

const LAST_BOOT: u32 = 10;
const REFLASH_WINDOW_S: u64 = 5;

const CONTROL_BUF_LEN: usize = 64;
const PRODUCT: &str = "exp160 secret too big";
const _: () = assert!(
    2 * PRODUCT.len() + 2 < CONTROL_BUF_LEN,
    "product string will overflow embassy-usb's control buffer and panic mid-enumeration"
);

/// A published, non-secret seed. FIPS-204 KeyGen is deterministic, so the public
/// key derived from this is a fixed value that OpenSSL and this crate agree on —
/// checked on a host before any of this was flashed. The board prints its own
/// answer and `verify.py` compares it against the constant, which is a check of
/// the board's cryptography that needs **no library on the reader's machine**.
///
/// It is not a key. It never reaches bank 8 and it never signs anything.
const KAT_SEED: [u8; SEED_LEN] = [0u8; SEED_LEN];

/// What the paint is, and why it is not zero: zero is what fresh SRAM and every
/// cleared buffer already look like, so a zeroed sweep region cannot tell
/// "nothing wrote here" from "something wrote zeros here".
const PAINT: u32 = 0xC5C5_C5C5;

/// Keep the paint floor clear of everything the linker placed. `__ebss` is the
/// top of the statics; a kilobyte above it is the first address that is only
/// ever stack.
const PAINT_MARGIN: usize = 1024;

/// How far below the current stack pointer to paint and then sweep.
///
/// `sign_once`'s own frame is 188,116 bytes, and the first attempt at this used
/// 320 KB on the strength of that number. **The measurement came back saturated:
/// the deepest painted word had been overwritten**, so one signature reaches
/// past its own frame by more than 139 KB in the functions it calls. This is
/// therefore set from what the board said rather than from the prologue, and
/// [`low_water`] now reports when it has hit its own limit instead of quoting
/// the limit as if it were a result.
const SWEEP_BYTES: usize = 460 * 1024;

const JOB_READ: u32 = 1;
const JOB_SIGN: u32 = 2;
const JOB_GRAB: u32 = 3;

extern "C" {
    static __ebss: u32;
}

/// The mailbox, in the **main** SRAM on purpose: `SRAM` defaults to fully open
/// access, so Non-secure asks by setting a flag and Secure answers by filling a
/// buffer, with nothing programmed to make it possible.
///
/// exp159 pointed out that the secret is in a different bank and only one side
/// can reach it. That is still true of bank 8. Candidate 5 is about what else
/// ends up in this region while the secret is being used.
static CORE1_UP: AtomicBool = AtomicBool::new(false);
static CORE1_GO: AtomicBool = AtomicBool::new(false);
static CORE1_JOB: AtomicU32 = AtomicU32::new(0);
static CORE1_READ: AtomicU32 = AtomicU32::new(0);
static CORE1_DONE: AtomicBool = AtomicBool::new(false);
static CORE1_FAULTED: AtomicBool = AtomicBool::new(false);
static SIGN_REQ: AtomicBool = AtomicBool::new(false);
static SIGN_DONE: AtomicBool = AtomicBool::new(false);
static SIG_SEEN: AtomicU32 = AtomicU32::new(0);
/// Where Secure found a copy of its own seed. Handed to Non-secure so that the
/// bytes come back through a core that is not allowed near bank 8.
static LEAK_ADDR: AtomicU32 = AtomicU32::new(0);
static STOPPED: AtomicBool = AtomicBool::new(false);

static mut SIGNATURE: [u8; SIG_LEN] = [0; SIG_LEN];
static mut PUBLIC_KEY: [u8; PK_LEN] = [0; PK_LEN];
static mut CHALLENGE: [u8; SEED_LEN] = [0; SEED_LEN];
/// The 32 bytes Non-secure code read out of open memory.
static mut CORE1_GRAB: [u8; SEED_LEN] = [0; SEED_LEN];
/// First 32 bytes of the public key derived from [`KAT_SEED`].
static mut KAT_PK_HEAD: [u8; SEED_LEN] = [0; SEED_LEN];

static mut CORE1_STACK: Stack<8192> = Stack::new();

/// Core 0 faulting is the case nothing else covers, so it goes to the harness.
/// Core 1 faulting is what candidate 3 is trying to cause, and it cannot reach
/// the watchdog anyway — `WATCHDOG` defaults to Secure-Privileged-only, so
/// `breadcrumb::reboot` from here would fault inside the fault handler.
#[exception]
unsafe fn HardFault(_ef: &ExceptionFrame) -> ! {
    if embassy_rp::pac::SIO.cpuid().read() != 0 {
        CORE1_FAULTED.store(true, Ordering::Relaxed);
        loop {
            cortex_m::asm::wfe();
        }
    }
    breadcrumb::reboot()
}

fn keystore_word(off: usize) -> u32 {
    unsafe { core::ptr::read_volatile((KEYSTORE + off) as *const u32) }
}

fn keystore_write(off: usize, v: u32) {
    unsafe { core::ptr::write_volatile((KEYSTORE + off) as *mut u32, v) }
}

fn keystore_seed() -> [u8; SEED_LEN] {
    let mut k = [0u8; SEED_LEN];
    for i in 0..8 {
        k[i * 4..i * 4 + 4].copy_from_slice(&keystore_word(4 + i * 4).to_be_bytes());
    }
    k
}

/// Open or shut bank 8 to Non-secure code. One register write, and it is the
/// only thing that differs between candidate 2 and candidate 3.
fn keystore_non_secure(allowed: bool) {
    let reg = embassy_rp::pac::ACCESSCTRL.sram(KEYSTORE_BANK);
    let before = reg.read().0;
    let bits = if allowed { before | NON_SECURE_BITS } else { before & !NON_SECURE_BITS };
    // Every ACCESSCTRL write needs 0xACCE in bits 31:16 — measured by exp156,
    // re-derived by exp158, and `modify()` would drop it every time.
    reg.write_value(embassy_rp::pac::accessctrl::regs::Access(0xACCE_0000 | (bits & 0xFFFF)));
}

fn demote_core1() {
    let r = embassy_rp::pac::ACCESSCTRL.force_core_ns();
    let cur = r.read().0;
    r.write_value(embassy_rp::pac::accessctrl::regs::ForceCoreNs(
        0xACCE_0000 | ((cur | 0b10) & 0xFFFF),
    ));
}

/// One signature, in one stack frame, with nothing held across an await.
///
/// `#[inline(never)]` is load-bearing twice over. It keeps the 65,696-byte
/// `SigningKey` out of the async task's future — which is a static, and would
/// have grown by that much — and it makes the frame a single measurable object,
/// which is what candidate 5 sweeps.
#[inline(never)]
fn sign_once(seed: &[u8; SEED_LEN], msg: &[u8], pk_out: &mut [u8; PK_LEN], sig_out: &mut [u8; SIG_LEN]) {
    let s: Seed = Array(*seed);
    let sk = SigningKey::<MlDsa65>::from_seed(&s);
    pk_out.copy_from_slice(sk.expanded_key().verifying_key().encode().as_slice());
    let sig = sk.expanded_key().sign_deterministic(msg, b"").unwrap();
    sig_out.copy_from_slice(sig.encode().as_slice());
}

/// The public key for [`KAT_SEED`], which is a fixed value the reader can check
/// without trusting this firmware.
#[inline(never)]
fn kat_public_head(out: &mut [u8; SEED_LEN]) {
    let s: Seed = Array(KAT_SEED);
    let sk = SigningKey::<MlDsa65>::from_seed(&s);
    let pk = sk.expanded_key().verifying_key().encode();
    out.copy_from_slice(&pk[..SEED_LEN]);
}

/// The address of a local, which is the current stack pointer near enough.
#[inline(never)]
fn stack_here() -> usize {
    let probe = 0u32;
    core::ptr::addr_of!(probe) as usize
}

fn paint_floor() -> usize {
    let ebss = core::ptr::addr_of!(__ebss) as usize;
    (ebss + PAINT_MARGIN + 3) & !3
}

/// Fill `[lo, hi)` with [`PAINT`]. Anything found in there afterwards was put
/// there afterwards, which is the whole reason candidate 5's answer means
/// something.
fn paint(lo: usize, hi: usize) {
    let mut a = lo;
    while a < hi {
        unsafe { core::ptr::write_volatile(a as *mut u32, PAINT) };
        a += 4;
    }
}

/// The lowest address in `[lo, hi)` that is no longer [`PAINT`], which is how
/// deep the stack went.
fn low_water(lo: usize, hi: usize) -> usize {
    let mut a = lo;
    while a < hi {
        if unsafe { core::ptr::read_volatile(a as *const u32) } != PAINT {
            return a;
        }
        a += 4;
    }
    hi
}

/// Count copies of `needle` in `[lo, hi)`, and return the address of the first.
fn sweep_for(needle: &[u8; SEED_LEN], lo: usize, hi: usize) -> (u32, u32) {
    let mut hits = 0u32;
    let mut first = 0u32;
    let mut a = lo;
    while a + SEED_LEN <= hi {
        let w = unsafe { core::slice::from_raw_parts(a as *const u8, SEED_LEN) };
        if w == needle {
            hits += 1;
            if first == 0 {
                first = a as u32;
            }
        }
        a += 1;
    }
    (hits, first)
}

/// What core 1 does. One job per boot, because each boot is one candidate.
fn core1_main() -> ! {
    CORE1_UP.store(true, Ordering::Relaxed);
    while !CORE1_GO.load(Ordering::Relaxed) {
        cortex_m::asm::nop();
    }

    match CORE1_JOB.load(Ordering::Relaxed) {
        // The read the wall exists to refuse. Non-secure by the time this runs.
        JOB_READ => {
            let v = unsafe { core::ptr::read_volatile(KEYSTORE as *const u32) };
            CORE1_READ.store(v, Ordering::Relaxed);
        }
        // Ask the Secure side for a signature and read the answer back out of
        // shared memory. Core 1 never touches bank 8 here.
        JOB_SIGN => {
            SIGN_REQ.store(true, Ordering::Relaxed);
            while !SIGN_DONE.load(Ordering::Relaxed) {
                cortex_m::asm::nop();
            }
            let sig = unsafe { &*core::ptr::addr_of!(SIGNATURE) };
            SIG_SEEN.store(u32::from_be_bytes([sig[0], sig[1], sig[2], sig[3]]), Ordering::Relaxed);
        }
        // Read 32 bytes from an ordinary address in the main SRAM. Nothing here
        // is privileged and nothing here is bank 8: this is the same region core
        // 1's own stack is in, and it is open by default.
        JOB_GRAB => {
            let mut waited = 0u32;
            while LEAK_ADDR.load(Ordering::Relaxed) == 0 && waited < 200_000_000 {
                cortex_m::asm::nop();
                waited += 1;
            }
            let a = LEAK_ADDR.load(Ordering::Relaxed) as usize;
            if a != 0 {
                let src = unsafe { core::slice::from_raw_parts(a as *const u8, SEED_LEN) };
                unsafe { (*core::ptr::addr_of_mut!(CORE1_GRAB)).copy_from_slice(src) };
            }
        }
        _ => {}
    }

    CORE1_DONE.store(true, Ordering::Relaxed);
    loop {
        cortex_m::asm::wfe();
    }
}

#[embassy_executor::task]
async fn heartbeat(mut led: Output<'static>) -> ! {
    loop {
        let (on, off) = if STOPPED.load(Ordering::Relaxed) { (100, 100) } else { (50, 950) };
        led.set_high();
        Timer::after(Duration::from_millis(on)).await;
        led.set_low();
        Timer::after(Duration::from_millis(off)).await;
    }
}

#[embassy_executor::task]
async fn usb_task(mut device: UsbDevice<'static, Driver<'static, USB>>) -> ! {
    device.run().await
}

#[embassy_executor::task]
async fn reboot_task(
    control: ControlChanged<'static>,
    receiver: Receiver<'static, usb_reboot::UsbDriver>,
) -> ! {
    usb_reboot::watch(control, receiver).await
}

#[embassy_executor::task]
async fn log_task(sender: Sender<'static, usb_reboot::UsbDriver>) -> ! {
    usb_log::run(sender).await
}

fn hex_into(buf: &mut [u8; 64], b: &[u8]) -> usize {
    const H: &[u8; 16] = b"0123456789abcdef";
    let mut n = 0;
    for &x in b {
        buf[n] = H[(x >> 4) as usize];
        buf[n + 1] = H[(x & 0x0f) as usize];
        n += 2;
    }
    n
}

/// Thirty-two bytes as one line of hex, sized to `usb-log`'s 96-byte line: the
/// reader's timestamp prefix is 14 characters, the tag is 4, and 64 hex
/// characters brings it to 83.
fn log_hex32(tag: &str, b: &[u8]) {
    let mut hb = [0u8; 64];
    let n = hex_into(&mut hb, &b[..SEED_LEN.min(b.len())]);
    log!("{} {}", tag, core::str::from_utf8(&hb[..n]).unwrap_or("??"));
}

/// A public key or a signature, 32 bytes at a time, each line carrying its own
/// index so a reader can reassemble them and know if one is missing.
///
/// Paced, because `usb-log`'s queue is 16 deep and drops the newest line when it
/// fills. 165 lines emitted in a tight loop would arrive as about 16.
async fn log_chunks(tag: &str, data: &[u8]) {
    for (i, c) in data.chunks(SEED_LEN).enumerate() {
        let mut hb = [0u8; 64];
        let n = hex_into(&mut hb, c);
        log!("{}{:03} {}", tag, i, core::str::from_utf8(&hb[..n]).unwrap_or("??"));
        Timer::after(Duration::from_millis(5)).await;
    }
}

fn candidate_name(n: u8) -> &'static str {
    match n {
        C_SECURE_SIGN => "1 Secure signs with the seed in bank 8",
        C_NS_READ_ALLOWED => "2 Non-secure reads bank 8, allowed",
        C_NS_READ_DENIED => "3 Non-secure reads bank 8, DENIED",
        C_NS_SIGN => "4 Non-secure asks for a signature",
        C_NS_FINDS_COPY => "5 Non-secure reads the copy on the stack",
        _ => "?",
    }
}

/// Every finding, on a loop. A fact printed once is a fact most readers miss.
fn report(note: &breadcrumb::Note) {
    for n in 1..=CANDIDATES {
        match note.outcome(n) {
            breadcrumb::NOT_ATTEMPTED => log!("  {} - not reached", candidate_name(n)),
            breadcrumb::DIED => log!("  {} - KILLED CORE 0", candidate_name(n)),
            breadcrumb::SURVIVED_A => log!("  {} - as expected", candidate_name(n)),
            _ => log!("  {} - NOT as expected", candidate_name(n)),
        }
    }
}

/// Bring core 1 up and demote it to Non-secure. Returns once it is spinning on
/// [`CORE1_GO`], which is set here as the last thing.
async fn launch_core1(core1: embassy_rp::Peri<'static, embassy_rp::peripherals::CORE1>, job: u32) {
    CORE1_JOB.store(job, Ordering::Relaxed);
    #[allow(static_mut_refs)]
    let stack = unsafe { &mut CORE1_STACK };
    spawn_core1(core1, stack, core1_main);
    while !CORE1_UP.load(Ordering::Relaxed) {
        Timer::after(Duration::from_millis(10)).await;
    }
    demote_core1();
    CORE1_GO.store(true, Ordering::Relaxed);
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let mut note = breadcrumb::read();

    let p = embassy_rp::init(Default::default());
    spawner.spawn(heartbeat(Output::new(p.PIN_25, Level::Low)).unwrap());

    let driver = Driver::new(p.USB, Irqs);
    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some(PRODUCT);
    config.serial_number = Some("160");
    config.device_class = 0xef;
    config.device_sub_class = 0x02;
    config.device_protocol = 0x01;
    config.composite_with_iads = true;

    static CONFIG_DESCRIPTOR: StaticCell<[u8; 256]> = StaticCell::new();
    static BOS_DESCRIPTOR: StaticCell<[u8; 256]> = StaticCell::new();
    static CONTROL_BUF: StaticCell<[u8; CONTROL_BUF_LEN]> = StaticCell::new();
    static ACM_STATE: StaticCell<State> = StaticCell::new();

    let mut builder = Builder::new(
        driver,
        config,
        CONFIG_DESCRIPTOR.init([0; 256]),
        BOS_DESCRIPTOR.init([0; 256]),
        &mut [],
        CONTROL_BUF.init([0; CONTROL_BUF_LEN]),
    );
    let class = CdcAcmClass::new(&mut builder, ACM_STATE.init(State::new()), 64);
    let usb = builder.build();
    spawner.spawn(usb_task(usb).unwrap());
    let (sender, receiver, control) = class.split_with_control();
    spawner.spawn(reboot_task(control, receiver).unwrap());
    spawner.spawn(log_task(sender).unwrap());

    // Report before risk, always.
    Timer::after(Duration::from_secs(3)).await;
    log!("exp160 up, boot #{}. The matrix so far:", note.boot);
    report(&note);

    // The seed. Generated here or already in bank 8 from a previous boot — which
    // also re-derives, for nothing, that bank 8 survives a watchdog reset.
    let mut trng = Trng::new(p.TRNG, Irqs, embassy_rp::trng::Config::default());
    let survived = keystore_word(0) == KEY_MAGIC;
    if survived {
        log!("bank 8 still holds this run's seed: it survived the reboot.");
    } else {
        // Every 32-byte string is a valid ML-DSA seed, so unlike exp159 there is
        // nothing to retry here.
        let mut k = [0u8; SEED_LEN];
        trng.blocking_fill_bytes(&mut k);
        for i in 0..8 {
            let mut w = [0u8; 4];
            w.copy_from_slice(&k[i * 4..i * 4 + 4]);
            keystore_write(4 + i * 4, u32::from_be_bytes(w));
        }
        keystore_write(0, KEY_MAGIC);
        log!("new ML-DSA-65 seed from the TRNG, written to bank 8 and nowhere else.");
    }

    let floor = paint_floor();
    let here = stack_here();
    log!("stack: sp near {:#010x}, floor {:#010x}, {} bytes of room", here, floor, here - floor);

    let next = note.next_unattempted(CANDIDATES);
    let finishing = next.is_none() || note.boot >= LAST_BOOT;

    if !finishing {
        let n = next.unwrap();

        log!("reflash window: {} s, nothing armed. `yi26 bootsel` works now.", REFLASH_WINDOW_S);
        Timer::after(Duration::from_secs(REFLASH_WINDOW_S)).await;

        breadcrumb::arm(STEP_BUDGET_US);
        breadcrumb::step(n);
        log!("candidate {}", candidate_name(n));

        let ok = match n {
            // Control, and a real question: 188 KB of stack frame is a third of
            // this chip. If one signature does not fit alongside the harness,
            // this is the candidate that says so by name.
            C_SECURE_SIGN => {
                let seed = keystore_seed();
                let mut challenge = [0u8; SEED_LEN];
                trng.blocking_fill_bytes(&mut challenge);

                let t0 = Instant::now();
                unsafe {
                    sign_once(
                        &seed,
                        &challenge,
                        &mut *core::ptr::addr_of_mut!(PUBLIC_KEY),
                        &mut *core::ptr::addr_of_mut!(SIGNATURE),
                    )
                };
                let took = t0.elapsed().as_millis();

                let pk = unsafe { &*core::ptr::addr_of!(PUBLIC_KEY) };
                let sg = unsafe { &*core::ptr::addr_of!(SIGNATURE) };
                log!("  one ML-DSA-65 signature in {} ms, {} bytes.", took, SIG_LEN);
                log_hex32("PKHD", &pk[..SEED_LEN]);
                log_hex32("SGHD", &sg[..SEED_LEN]);
                pk.iter().any(|b| *b != 0) && sg.iter().any(|b| *b != 0)
            }

            // The two that differ by one register write, and nothing else.
            C_NS_READ_ALLOWED | C_NS_READ_DENIED => {
                let allow = n == C_NS_READ_ALLOWED;
                keystore_non_secure(allow);
                log!("  bank {} to Non-secure: {}", KEYSTORE_BANK, if allow { "OPEN" } else { "SHUT" });

                launch_core1(p.CORE1, JOB_READ).await;
                Timer::after(Duration::from_secs(1)).await;

                let faulted = CORE1_FAULTED.load(Ordering::Relaxed);
                let done = CORE1_DONE.load(Ordering::Relaxed);
                let v = CORE1_READ.load(Ordering::Relaxed);
                log!("  core 1: done={} faulted={} read={:#010x}", done, faulted, v);

                if allow {
                    done && !faulted && v == KEY_MAGIC
                } else {
                    faulted && !done
                }
            }

            // exp159's headline, ported. It passes — and candidate 5 is why that
            // is not the end of the sentence.
            C_NS_SIGN => {
                keystore_non_secure(false);
                log!("  bank {} SHUT, and it stays shut while the seed is used.", KEYSTORE_BANK);

                let seed = keystore_seed();
                let mut challenge = [0u8; SEED_LEN];
                trng.blocking_fill_bytes(&mut challenge);
                log_hex32("MSG ", &challenge[..]);

                launch_core1(p.CORE1, JOB_SIGN).await;

                let mut waited = 0;
                while !SIGN_REQ.load(Ordering::Relaxed) && waited < 200 {
                    Timer::after(Duration::from_millis(10)).await;
                    waited += 1;
                }
                let asked = SIGN_REQ.load(Ordering::Relaxed);
                log!("  Non-secure asked for a signature: {}", asked);

                let t0 = Instant::now();
                unsafe {
                    sign_once(
                        &seed,
                        &challenge,
                        &mut *core::ptr::addr_of_mut!(PUBLIC_KEY),
                        &mut *core::ptr::addr_of_mut!(SIGNATURE),
                    )
                };
                let took = t0.elapsed().as_millis();
                SIGN_DONE.store(true, Ordering::Relaxed);
                log!("  Secure signed it in {} ms, {} bytes into the mailbox.", took, SIG_LEN);

                Timer::after(Duration::from_millis(500)).await;
                let sg = unsafe { &*core::ptr::addr_of!(SIGNATURE) };
                let expect = u32::from_be_bytes([sg[0], sg[1], sg[2], sg[3]]);
                let seen = SIG_SEEN.load(Ordering::Relaxed);
                log!("  Non-secure read it back: {:#010x} (want {:#010x})", seen, expect);

                asked && seen == expect && !CORE1_FAULTED.load(Ordering::Relaxed)
            }

            // The finding. Bank 8 stays shut throughout, exactly as in candidate
            // 4 — and the key is read by Non-secure code anyway.
            C_NS_FINDS_COPY => {
                keystore_non_secure(false);
                log!("  bank {} SHUT for this whole candidate.", KEYSTORE_BANK);

                let seed = keystore_seed();
                let mut challenge = [0u8; SEED_LEN];
                trng.blocking_fill_bytes(&mut challenge);
                unsafe { (*core::ptr::addr_of_mut!(CHALLENGE)).copy_from_slice(&challenge) };

                launch_core1(p.CORE1, JOB_GRAB).await;

                // Paint first. Anything found later was written later, and that
                // is what makes the sweep an observation rather than a coincidence.
                let hi = (stack_here() - 64) & !3;
                let lo = core::cmp::max(paint_floor(), hi.saturating_sub(SWEEP_BYTES));
                paint(lo, hi);
                log!("  painted {} bytes of stack below {:#010x} with 0xc5.", hi - lo, hi);

                let t0 = Instant::now();
                unsafe {
                    sign_once(
                        &seed,
                        &challenge,
                        &mut *core::ptr::addr_of_mut!(PUBLIC_KEY),
                        &mut *core::ptr::addr_of_mut!(SIGNATURE),
                    )
                };
                let took = t0.elapsed().as_millis();

                let deepest = low_water(lo, hi);
                if deepest == lo {
                    // The instrument ran out of room. Say so: a saturated
                    // measurement quoted as a result is a number that means the
                    // opposite of what it looks like.
                    log!("  signed in {} ms; the stack went past {} bytes - SATURATED, not a depth.", took, hi - lo);
                } else {
                    log!("  signed in {} ms; the stack went down to {:#010x}, {} bytes deep.", took, deepest, hi - deepest);
                }

                let (hits, first) = sweep_for(&seed, lo, hi);
                log!("  copies of the 32-byte seed left in open SRAM: {}", hits);

                if hits == 0 {
                    log!("  nothing found. The wall covered it after all.");
                    // Release core 1 with a valid address rather than a
                    // sentinel, so a null finding does not also fault it and
                    // give the log two things to explain instead of one.
                    LEAK_ADDR.store(lo as u32, Ordering::Relaxed);
                    Timer::after(Duration::from_millis(500)).await;
                    false
                } else {
                    log!("  first copy at {:#010x}, outside bank 8, in the main 512 KB.", first);
                    LEAK_ADDR.store(first, Ordering::Relaxed);

                    let mut waited = 0;
                    while !CORE1_DONE.load(Ordering::Relaxed) && waited < 200 {
                        Timer::after(Duration::from_millis(10)).await;
                        waited += 1;
                    }
                    let grabbed = unsafe { &*core::ptr::addr_of!(CORE1_GRAB) };
                    let matched = grabbed == &seed;
                    log!("  core 1 read 32 bytes from there: done={} faulted={}",
                         CORE1_DONE.load(Ordering::Relaxed), CORE1_FAULTED.load(Ordering::Relaxed));
                    log!("  they are the key: {}", if matched { "MATCH" } else { "no" });
                    // Eight bytes, not thirty-two. The comparison above is over
                    // all of them and happens on the board; what goes in the log
                    // is a fingerprint. An experiment whose finding is that a
                    // private key leaked should not be the thing that publishes
                    // it — this log is pasted into READMEs and rendered by web
                    // pages, and the seed is regenerated on every flash but that
                    // is not a reason to print it.
                    let mut hb = [0u8; 64];
                    let n = hex_into(&mut hb, &grabbed[..8]);
                    log!("  GRAB {}... (8 of 32; the board compared all of them)",
                         core::str::from_utf8(&hb[..n]).unwrap_or("??"));
                    matched && !CORE1_FAULTED.load(Ordering::Relaxed)
                }
            }

            _ => false,
        };

        breadcrumb::mark(n, if ok { breadcrumb::SURVIVED_A } else { breadcrumb::SURVIVED_B });
        // The note was a snapshot taken at boot, so it does not know about the
        // mark just made. Without this the final report says "not reached"
        // about the candidate it has this second finished.
        note.steps = breadcrumb::steps_now();
        log!("candidate {} -> {}", n, if ok { "as expected" } else { "NOT as expected" });
        breadcrumb::finished();

        // Every candidate but the last goes round again. The last one does NOT
        // reboot: its public key, challenge and signature live in RAM and a
        // reboot would take them with it. Bank 8 is the seed's and flash is the
        // one place this experiment refuses to write, so the run ends here
        // holding its own evidence.
        if n != CANDIDATES {
            Timer::after(Duration::from_millis(300)).await;
            breadcrumb::reboot()
        }
    }

    breadcrumb::disarm();
    STOPPED.store(true, Ordering::Relaxed);

    // The one check of the board's cryptography that needs nothing installed.
    // FIPS-204 KeyGen is deterministic, so this public key has one correct
    // value, and OpenSSL and this crate were made to agree on it off the board.
    unsafe { kat_public_head(&mut *core::ptr::addr_of_mut!(KAT_PK_HEAD)) };

    loop {
        log!("exp160 done after {} boots. Nothing armed; still reflashable.", note.boot);
        report(&note);
        let katp = unsafe { &*core::ptr::addr_of!(KAT_PK_HEAD) };
        log_hex32("KATP", &katp[..]);

        // The whole proof, repeating, so arriving late costs nothing — 173 lines
        // of it, which is what a post-quantum signature costs a 96-byte channel.
        if SIGN_DONE.load(Ordering::Relaxed) || note.outcome(C_NS_FINDS_COPY) != breadcrumb::NOT_ATTEMPTED {
            let msg = unsafe { &*core::ptr::addr_of!(CHALLENGE) };
            log_hex32("MSG ", &msg[..]);
            let pk = unsafe { &*core::ptr::addr_of!(PUBLIC_KEY) };
            log_chunks("PK", &pk[..]).await;
            let sg = unsafe { &*core::ptr::addr_of!(SIGNATURE) };
            log_chunks("SG", &sg[..]).await;
        }
        Timer::after(Duration::from_secs(4)).await;
    }
}
