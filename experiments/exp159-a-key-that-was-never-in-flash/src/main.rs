//! exp159 — a key that was never in flash.
//!
//! The third experiment on the [signing road](../README.md#the-signing-road),
//! and the first one written as a **matrix from the start** — see
//! [`docs/the-board-is-the-loop.md`](../../docs/the-board-is-the-loop.md). Four
//! measurements, one per boot, one flash. If an early one fails the later ones
//! say *not reached* instead of the whole trip being wasted.
//!
//! # The claim
//!
//! > **A P-256 private key exists on this board in a place Non-secure code
//! > cannot read, it never existed in flash, and it produced a signature over a
//! > challenge nobody could have known at build time — checked by something that
//! > is not this firmware.**
//!
//! # Three contradictions, and what each one forced
//!
//! ## 1. exp156's wall is around a peripheral. A key is bytes.
//!
//! [exp156](../exp156-a-wall-you-can-measure/) measured `ACCESSCTRL` denying
//! **I2C1** to Non-secure code, and explicitly rejected doing the same to SRAM:
//! *"denying Non-secure access to SRAM or to XIP would take core 1's own stack
//! and code away before it reached the thing being tested."* That is true, and a
//! key is not a peripheral, so the wall as measured cannot hold one.
//!
//! `ACCESSCTRL` gates **each of ten SRAM banks separately**, and the RP2350's
//! 520 KB is 8 × 64 KB plus **two 4 KB banks of their own**. So the key lives in
//! bank 8, at [`KEYSTORE`], and core 1's stack stays in the main region. Nothing
//! core 1 needs is ever denied to it.
//!
//! This also sidesteps a fact nobody here has measured: whether banks 0–7 are
//! striped across the main address range. **It stops mattering**, because those
//! banks are never touched.
//!
//! ## 2. A key compiled into the firmware makes the whole thing hollow.
//!
//! This is the one worth stopping on, because it is the defect this road was
//! filed against arriving from a new direction.
//!
//! If the private key were a constant in the source, it would live in flash. And
//! `XIP_MAIN` **defaults to fully open access** — Non-secure code reads flash
//! perfectly well; that is how core 1 executes at all. So the wall around bank 8
//! would be guarding a *copy* while the original sat in the open, and the
//! demonstration would be theatre.
//!
//! So the key is generated **on the board, from the hardware TRNG, into bank 8,
//! and never written anywhere else**. The firmware prints the *public* key. What
//! is in flash is code, not a secret.
//!
//! (`TRNG` itself defaults to *Secure, Privileged only*, so the generator is out
//! of Non-secure reach without anyone programming anything.)
//!
//! ## 3. The road said "hand-write an SG veneer and program the SAU".
//!
//! It does not need one. exp156 put the boundary **between the two cores** with
//! `ACCESSCTRL.FORCE_CORE_NS`, and a boundary between cores has no veneer: the
//! gateway is a mailbox. No `global_asm!`, no SAU, no nightly.
//!
//! The mailbox is **shared memory, not the SIO FIFO**, and that is measured
//! rather than preferred: `embassy-rp`'s `multicore` keeps using the FIFO after
//! launch for its pause/resume tokens, so a second user of it would collide.
//!
//! # Why core 1's fault handler parks instead of rebooting
//!
//! `WATCHDOG` defaults to *Secure, Privileged only*. A Non-secure core cannot
//! reach it, so [`breadcrumb::reboot`] from core 1 would fault **inside the fault
//! handler**. Core 1 therefore sets a flag in shared memory and parks, and core 0
//! — still Secure, still holding USB — notices and reports. That is exp156's
//! shape, and here it is forced by a register default rather than chosen.
//!
//! The breadcrumb harness is still underneath all of it, as the net for the case
//! nothing else covers: a death that takes **core 0**.
//!
//! # The matrix
//!
//! ```text
//!   1  Secure core 0 reads the key out of bank 8        must work   (control)
//!   2  Non-secure core 1 reads bank 8, allowed          must work   (control)
//!   3  Non-secure core 1 reads bank 8, denied           must be refused
//!   4  Non-secure core 1 asks for a signature,
//!      with bank 8 still denied                         64 bytes come back
//! ```
//!
//! Candidates 1 and 2 are not decoration. A refusal on its own is one failed
//! access; **the same core reading the same address a moment earlier is what
//! makes the refusal mean something**, and that is the shape exp156 arrived at
//! after eight rounds.

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
use p256::ecdsa::{signature::Signer, Signature, SigningKey};
use panic_halt as _;
use rp2350_linker as _;
use static_cell::StaticCell;
use usb_log::log;

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
    TRNG_IRQ => embassy_rp::trng::InterruptHandler<TRNG>;
});

/// SRAM bank 8: 4 KB of its own, immediately above the main 512 KB.
///
/// Not in `rp2350-linker`'s memory map, which is exactly why it is usable for
/// this: nothing the linker places can land here by accident, so the only things
/// in this bank are the ones put there on purpose.
const KEYSTORE: usize = 0x2008_0000;

/// Which `ACCESSCTRL.SRAM[n]` register gates [`KEYSTORE`].
///
/// **Assumed, and the experiment checks its own assumption.** If bank 8 is not
/// this register, candidate 3 will not be refused and the run says so — which is
/// a finding, not a silent pass.
const KEYSTORE_BANK: usize = 8;

/// Marks the bank as holding a key this firmware generated. Also answers, for
/// free, whether bank 8 survives a watchdog reset.
const KEY_MAGIC: u32 = 0x4B45_5931;

/// NSU (bit 0) and NSP (bit 1) — the two bits that are the wall. exp156
/// established the field order from silicon: the PAC's names and positions are
/// right and its doc comments are shifted by one field.
const NON_SECURE_BITS: u32 = 0b11;

const C_SECURE_READ: u8 = 1;
const C_NS_READ_ALLOWED: u8 = 2;
const C_NS_READ_DENIED: u8 = 3;
const C_NS_SIGN: u8 = 4;
const CANDIDATES: u8 = 4;

/// Generous, because one P-256 signature is the slowest thing here and nobody
/// has timed it on this part yet. A budget shorter than a step that was going to
/// succeed reports a death that never happened.
const STEP_BUDGET_US: u32 = 12_000_000;

const LAST_BOOT: u32 = 8;
const REFLASH_WINDOW_S: u64 = 5;

const CONTROL_BUF_LEN: usize = 64;
const PRODUCT: &str = "exp159 key never in flash";
const _: () = assert!(
    2 * PRODUCT.len() + 2 < CONTROL_BUF_LEN,
    "product string will overflow embassy-usb's control buffer and panic mid-enumeration"
);

const JOB_READ: u32 = 1;
const JOB_SIGN: u32 = 2;

/// The mailbox, and it lives in the **main** SRAM on purpose.
///
/// `SRAM` defaults to fully open access, so a Non-secure core writes here
/// without anything being programmed. That is the whole gateway: Non-secure asks
/// by setting a flag, Secure answers by filling a buffer. The secret is in a
/// different bank, and only one side can reach it.
static CORE1_UP: AtomicBool = AtomicBool::new(false);
static CORE1_GO: AtomicBool = AtomicBool::new(false);
static CORE1_JOB: AtomicU32 = AtomicU32::new(0);
static CORE1_READ: AtomicU32 = AtomicU32::new(0);
static CORE1_DONE: AtomicBool = AtomicBool::new(false);
static CORE1_FAULTED: AtomicBool = AtomicBool::new(false);
static SIGN_REQ: AtomicBool = AtomicBool::new(false);
static SIGN_DONE: AtomicBool = AtomicBool::new(false);
static SIG_SEEN: AtomicU32 = AtomicU32::new(0);
static mut SIGNATURE: [u8; 64] = [0; 64];
static mut CHALLENGE: [u8; 32] = [0; 32];
static STOPPED: AtomicBool = AtomicBool::new(false);

static mut CORE1_STACK: Stack<8192> = Stack::new();

/// Core 0 faulting is the case nothing else covers, so it goes to the harness.
/// Core 1 faulting is what candidate 3 is *trying* to cause, and it cannot reach
/// the watchdog anyway — so it leaves a flag and parks, and core 0 reports it.
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

fn keystore_key() -> [u8; 32] {
    let mut k = [0u8; 32];
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
        // Ask the Secure side for a signature over the challenge, and read the
        // answer back out of shared memory. Core 1 never touches bank 8 here.
        JOB_SIGN => {
            SIGN_REQ.store(true, Ordering::Relaxed);
            while !SIGN_DONE.load(Ordering::Relaxed) {
                cortex_m::asm::nop();
            }
            let sig = unsafe { &*core::ptr::addr_of!(SIGNATURE) };
            SIG_SEEN.store(u32::from_be_bytes([sig[0], sig[1], sig[2], sig[3]]), Ordering::Relaxed);
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

/// Thirty-two bytes as one line of hex.
///
/// Sized to `usb-log`'s 96-byte line with its timestamp prefix: a four-character
/// tag plus 64 hex characters fits, and 65 bytes on one line would not. exp156
/// lost its headline finding to that limit.
fn log_hex32(tag: &str, b: &[u8]) {
    let w = |i: usize| u32::from_be_bytes([b[i], b[i + 1], b[i + 2], b[i + 3]]);
    log!(
        "{} {:08x}{:08x}{:08x}{:08x}{:08x}{:08x}{:08x}{:08x}",
        tag, w(0), w(4), w(8), w(12), w(16), w(20), w(24), w(28)
    );
}

fn candidate_name(n: u8) -> &'static str {
    match n {
        C_SECURE_READ => "1 Secure reads the key",
        C_NS_READ_ALLOWED => "2 Non-secure reads it, allowed",
        C_NS_READ_DENIED => "3 Non-secure reads it, DENIED",
        C_NS_SIGN => "4 Non-secure asks for a signature",
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

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let mut note = breadcrumb::read();

    let p = embassy_rp::init(Default::default());
    spawner.spawn(heartbeat(Output::new(p.PIN_25, Level::Low)).unwrap());

    let driver = Driver::new(p.USB, Irqs);
    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some(PRODUCT);
    config.serial_number = Some("159");
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
    log!("exp159 up, boot #{}. The matrix so far:", note.boot);
    report(&note);

    // The key. Generated here or already in bank 8 from a previous boot — which
    // also answers, for nothing, whether bank 8 survives a watchdog reset.
    let mut trng = Trng::new(p.TRNG, Irqs, embassy_rp::trng::Config::default());
    let survived = keystore_word(0) == KEY_MAGIC;
    if survived {
        log!("bank 8 still holds this run's key: it survived the reboot.");
    } else {
        let mut k = [0u8; 32];
        loop {
            trng.blocking_fill_bytes(&mut k);
            if SigningKey::from_bytes(&k.into()).is_ok() {
                break;
            }
        }
        for i in 0..8 {
            let mut w = [0u8; 4];
            w.copy_from_slice(&k[i * 4..i * 4 + 4]);
            keystore_write(4 + i * 4, u32::from_be_bytes(w));
        }
        keystore_write(0, KEY_MAGIC);
        log!("new P-256 key from the TRNG, written to bank 8 and nowhere else.");
    }

    let signing = SigningKey::from_bytes(&keystore_key().into()).unwrap();
    let vk = signing.verifying_key();
    let pt = vk.to_encoded_point(false);
    log_hex32("PUBX", pt.x().unwrap());
    log_hex32("PUBY", pt.y().unwrap());

    let next = note.next_unattempted(CANDIDATES);
    if next.is_none() || note.boot >= LAST_BOOT {
        breadcrumb::disarm();
        STOPPED.store(true, Ordering::Relaxed);
        loop {
            log!("exp159 done after {} boots. Nothing armed; still reflashable.", note.boot);
            report(&note);
            Timer::after(Duration::from_secs(10)).await;
        }
    }
    let n = next.unwrap();

    log!("reflash window: {} s, nothing armed. `yi26 bootsel` works now.", REFLASH_WINDOW_S);
    Timer::after(Duration::from_secs(REFLASH_WINDOW_S)).await;

    breadcrumb::arm(STEP_BUDGET_US);
    breadcrumb::step(n);
    log!("candidate {}", candidate_name(n));

    let ok = match n {
        // Control. Also proves bank 8 is real, writable RAM at that address.
        C_SECURE_READ => {
            let magic = keystore_word(0);
            let first = keystore_word(4);
            log!("  Secure read: magic {:#010x}, first key word {:#010x}", magic, first);
            magic == KEY_MAGIC && first != 0
        }

        // The two that differ by one register write, and nothing else.
        C_NS_READ_ALLOWED | C_NS_READ_DENIED => {
            let allow = n == C_NS_READ_ALLOWED;
            keystore_non_secure(allow);
            log!("  bank {} to Non-secure: {}", KEYSTORE_BANK, if allow { "OPEN" } else { "SHUT" });

            CORE1_JOB.store(JOB_READ, Ordering::Relaxed);
            #[allow(static_mut_refs)]
            let stack = unsafe { &mut CORE1_STACK };
            spawn_core1(p.CORE1, stack, core1_main);
            while !CORE1_UP.load(Ordering::Relaxed) {
                Timer::after(Duration::from_millis(10)).await;
            }
            demote_core1();
            CORE1_GO.store(true, Ordering::Relaxed);
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

        // The point of the whole road: the key is used without being readable.
        C_NS_SIGN => {
            keystore_non_secure(false);
            log!("  bank {} SHUT, and it stays shut while the key is used.", KEYSTORE_BANK);

            let mut challenge = [0u8; 32];
            trng.blocking_fill_bytes(&mut challenge);
            unsafe { (*core::ptr::addr_of_mut!(CHALLENGE)).copy_from_slice(&challenge) };
            log_hex32("MSG ", &challenge);

            CORE1_JOB.store(JOB_SIGN, Ordering::Relaxed);
            #[allow(static_mut_refs)]
            let stack = unsafe { &mut CORE1_STACK };
            spawn_core1(p.CORE1, stack, core1_main);
            while !CORE1_UP.load(Ordering::Relaxed) {
                Timer::after(Duration::from_millis(10)).await;
            }
            demote_core1();
            CORE1_GO.store(true, Ordering::Relaxed);

            // Wait for the Non-secure side to ask.
            let mut waited = 0;
            while !SIGN_REQ.load(Ordering::Relaxed) && waited < 200 {
                Timer::after(Duration::from_millis(10)).await;
                waited += 1;
            }
            let asked = SIGN_REQ.load(Ordering::Relaxed);
            log!("  Non-secure asked for a signature: {}", asked);

            let t0 = Instant::now();
            let sig: Signature = signing.sign(&challenge);
            let took = t0.elapsed().as_millis();
            let bytes = sig.to_bytes();
            unsafe {
                let dst = &mut *core::ptr::addr_of_mut!(SIGNATURE);
                dst.copy_from_slice(&bytes);
            }
            SIGN_DONE.store(true, Ordering::Relaxed);
            log!("  Secure signed it in {} ms.", took);
            log_hex32("SIGR", &bytes[..32]);
            log_hex32("SIGS", &bytes[32..]);

            Timer::after(Duration::from_millis(500)).await;
            let seen = SIG_SEEN.load(Ordering::Relaxed);
            let expect = u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
            log!("  Non-secure read it back: {:#010x} (want {:#010x})", seen, expect);

            asked && seen == expect && !CORE1_FAULTED.load(Ordering::Relaxed)
        }

        _ => false,
    };

    breadcrumb::mark(n, if ok { breadcrumb::SURVIVED_A } else { breadcrumb::SURVIVED_B });
    // The note was a snapshot taken at boot, so it does not know about the mark
    // just made. Without this the final report says "not reached" about the
    // candidate it has this second finished — which it did, on the first run.
    note.steps = breadcrumb::steps_now();
    log!("candidate {} -> {}", n, if ok { "as expected" } else { "NOT as expected" });
    breadcrumb::finished();

    // Every candidate but the last goes round again. The last one does NOT
    // reboot, and that is deliberate: its challenge and signature live in RAM,
    // and a reboot would take them with it. There is nowhere else to put them —
    // bank 8 is the key's, and flash is the one place this experiment refuses to
    // write. So the run ends here, holding its own evidence.
    if n != CANDIDATES {
        Timer::after(Duration::from_millis(300)).await;
        breadcrumb::reboot()
    }

    breadcrumb::disarm();
    STOPPED.store(true, Ordering::Relaxed);
    loop {
        log!("exp159 done after {} boots. Nothing armed; still reflashable.", note.boot);
        report(&note);
        // The whole proof, repeating, so arriving late costs nothing. The
        // verifier needs all four lines and it is not this firmware.
        log_hex32("PUBX", pt.x().unwrap());
        log_hex32("PUBY", pt.y().unwrap());
        if SIGN_DONE.load(Ordering::Relaxed) {
            let c = unsafe { &*core::ptr::addr_of!(CHALLENGE) };
            let g = unsafe { &*core::ptr::addr_of!(SIGNATURE) };
            log_hex32("MSG ", c);
            log_hex32("SIGR", &g[..32]);
            log_hex32("SIGS", &g[32..]);
        }
        Timer::after(Duration::from_secs(10)).await;
    }
}
