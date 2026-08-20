//! exp156 — a wall you can measure.
//!
//! [exp154](../exp154-somewhere-to-put-a-key/) asked the chip whether it
//! already had somewhere to keep a secret and got a clean answer: **no**.
//! Not one of 4096 OTP rows refused to be read. OTP on a stock part is a place
//! to *store* a key, not a place that *hides* one, so the boundary the
//! [signing road](../README.md#the-signing-road) needs has to be built.
//!
//! This builds the smallest one that can be shown to work, and **there is no
//! cryptography in it at all**. A key behind a boundary nobody demonstrated is
//! the defect this whole road was filed against: prior work outside this
//! repository named a function `tfm_secure_ecdsa_sign`, gave it the
//! secure-gateway ABI, and never programmed a thing — so what it proved was
//! that a function can be *called*, while the claim on the label was that a key
//! cannot be *read*. [exp140](../exp140-a-checksum-that-passes/) is the same
//! defect seen from the other side: a check that cannot fail has not passed.
//!
//! So the only claim here is: **this address is readable from one place and
//! not from another, and both halves were watched.**
//!
//! # How the wall is built, and why not the way the road first said
//!
//! The plan said "program the SAU". The SAU is the Cortex-M33's own
//! partitioning of the *address space*, and it is one of two walls on this
//! chip. The other is **ACCESSCTRL**, which gates requests at the far end of
//! the bus, per peripheral, by who is asking and in what security state — and
//! it is the one this experiment uses, for three reasons that are worth stating
//! because the choice is not obvious:
//!
//! 1. **`embassy-rp` has no SAU support whatsoever.** Asked before planning
//!    around it: not one file in the HAL mentions SAU, TrustZone or
//!    Non-secure. `rp-pac`, on the other hand, models ACCESSCTRL in full.
//! 2. **ACCESSCTRL can put a whole core into Non-secure state** —
//!    `FORCE_CORE_NS.CORE1` — with no hand-written `SG` veneer and no `BXNS`.
//!    The veneer is still coming; it belongs to the experiment that has code on
//!    both sides of the line, not to the one measuring whether the line exists.
//! 3. **It puts the fault on a different core from the log.** That is the
//!    problem the road wrote down and did not solve: a firmware that proves its
//!    point by faulting takes USB with it and says nothing, and
//!    [exp134](../exp134-the-log-nobody-reads/) is the record of how many ways
//!    silence reads. Here core 1 faults and **core 0 is still talking**.
//!
//! # The shape
//!
//! ```text
//!   core 0  Secure, privileged           core 1  the core being measured
//!   ---------------------------------    ------------------------------------
//!   owns USB, prints everything
//!                                        read 1  Secure,     open -> a value
//!   opens I2C1 to Non-secure    ---->
//!   FORCE_CORE_NS.CORE1         ---->
//!                                        read 2  Non-secure, open -> a value
//!   shuts I2C1 to Non-secure    ---->
//!                                        read 3  Non-secure, SHUT -> BusFault
//!   reports all three                    handler records it and parks
//! ```
//!
//! **One core, one address, one thing changed at a time.** Read 1 to read 2
//! changes only the security state, so it says a demoted core still executes.
//! Read 2 to read 3 changes only the ACCESSCTRL bits, so what refuses read 3
//! can only be ACCESSCTRL.
//!
//! An earlier build took reads 1 and 3 alone and called the difference a wall.
//! It was wrong twice over. It changed two things at once, so "ACCESSCTRL
//! refused it" and "a Non-secure core cannot run" were the same outcome. And
//! `ACCESSCTRL.I2C1` reads `0x0000_00fc` at power-on, which **already** denies
//! Non-secure — so the firmware's "deny" write changed nothing and the fault
//! would have happened had this experiment never run. It had photographed a
//! wall the bootrom left standing and put its own name on it.
//!
//! Opening the wall before shutting it is what turned that into a measurement.
//!
//! # What it does not touch
//!
//! Nothing is locked. `ACCESSCTRL.LOCK` makes a configuration permanent until
//! reset and this never writes it, so a board that ends up in a state you did
//! not want is one power cycle from being ordinary again. It is *read*, and it
//! comes back `0x0000_0004` — bit 2, DMA, locked out of ACCESSCTRL by the
//! bootrom before this firmware ever ran.
//!
//! The peripheral is **I2C1**, chosen because nothing in this firmware uses it.
//! Denying Non-secure access to SRAM or to XIP would take core 1's own stack
//! and code away before it reached the thing being tested, and denying it to
//! USB would take the log.

#![no_std]
#![no_main]

use core::sync::atomic::{AtomicBool, AtomicU32, Ordering};

use cortex_m_rt::{exception, ExceptionFrame};
use embassy_executor::Spawner;
use embassy_rp::bind_interrupts;
use embassy_rp::gpio::{Level, Output};
use embassy_rp::multicore::{spawn_core1, Stack};
use embassy_rp::peripherals::USB;
use embassy_rp::usb::{Driver, InterruptHandler};
use embassy_time::{Duration, Timer};
use embassy_usb::class::cdc_acm::{CdcAcmClass, ControlChanged, Receiver, Sender, State};
use embassy_usb::{Builder, Config as UsbConfig, UsbDevice};
use panic_halt as _;
use rp2350_linker as _;
use static_cell::StaticCell;
use usb_log::log;

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
});

/// The address both cores try to read.
///
/// I2C1's hardware ID register: a constant the block returns whatever state it
/// is in, so a successful read is unambiguous and an unsuccessful one is not a
/// side effect of the peripheral being unconfigured.
///
/// Taken from the PAC rather than written down. The first draft of this line
/// hardcoded `0x4009_0000`, which is **I2C0** — so it would have denied one
/// peripheral and read another, reported *no wall*, and been believed. An
/// address that has to agree with a register block is an address the register
/// block should supply.
fn target() -> *const u32 {
    embassy_rp::pac::I2C1.ic_comp_type().as_ptr() as *const u32
}

/// Steps core 1 records as it goes.
///
/// Not progress for its own sake. Core 1 is about to be denied something on
/// purpose, and the whole question is *where* it stops — so it says where it
/// got to before each step rather than after, and core 0 reports the last
/// number it saw. A run that ends at 0 is a core that never started, and that
/// looked identical to a core that was refused until this counter existed.
///
/// Core 1 reads the same address **three** times, and the middle one is why
/// this build exists. The first run of this experiment on hardware measured a
/// Secure read that worked and a Non-secure read that faulted, and called that
/// a wall — but the power-on value of `ACCESSCTRL.I2C1` turned out to be
/// `0xfc`, which already denied Non-secure. The firmware had written nothing;
/// it had photographed a wall the bootrom left standing. Worse, one run cannot
/// tell *ACCESSCTRL refused the read* apart from *a demoted core cannot execute
/// at all*, and those are different findings.
///
/// So the middle read is taken Non-secure with the wall deliberately **open**.
/// It succeeds or the rest means nothing.
const STEP_NONE: u32 = 0;
const STEP_ALIVE: u32 = 1;
const STEP_SECURE_READ: u32 = 2;
const STEP_ABOUT_TO_READ_OPEN: u32 = 3;
const STEP_OPEN_READ: u32 = 4;
const STEP_ABOUT_TO_READ_SHUT: u32 = 5;
const STEP_SHUT_READ: u32 = 6;

/// What core 0 found in ACCESSCTRL, kept so the repeating summary can say it.
///
/// The ladder prints these once, six seconds in. `usb-log`'s outgoing queue is
/// sixteen lines deep and nothing drains it until a host asserts DTR, so a
/// reader who plugs in late gets `(+12 lines lost)` and none of them — and the
/// power-on value of `ACCESSCTRL.I2C1` is not a step, it is a **finding**.
/// AGENTS.md lists "the fact printed once that nobody sees" among the mistakes
/// this repository has already paid for. So every finding goes in the block
/// that repeats, and only the narrative is allowed to scroll away.
static SAW_LOCK: AtomicU32 = AtomicU32::new(0);
static SAW_BEFORE: AtomicU32 = AtomicU32::new(0);
static SAW_OPENED: AtomicU32 = AtomicU32::new(0);
static SAW_SHUT: AtomicU32 = AtomicU32::new(0);

static CORE1_STEP: AtomicU32 = AtomicU32::new(STEP_NONE);
static CORE1_SECURE: AtomicU32 = AtomicU32::new(0);
static CORE1_OPEN: AtomicU32 = AtomicU32::new(0);
static CORE1_SHUT: AtomicU32 = AtomicU32::new(0);
static GO_OPEN: AtomicBool = AtomicBool::new(false);
static GO_SHUT: AtomicBool = AtomicBool::new(false);

/// Which rung the ladder is on, for the fault handler to blink.
///
/// The handler already proved that a dead core 0 can announce itself. What it
/// could not say was *where*, so the count had to come from somebody watching
/// a clock — and a pattern that means "died" is worth much less than one that
/// means "died here". This is written before each step, never after, so the
/// number blinked is the step that did not come back.
static LADDER: AtomicU32 = AtomicU32::new(0);
static FAULTED: AtomicBool = AtomicBool::new(false);
static FAULT_PC: AtomicU32 = AtomicU32::new(0);

static mut CORE1_STACK: Stack<4096> = Stack::new();

/// Where the denied read lands.
///
/// This runs on whichever core faulted. Core 1 is the one expected here, and it
/// records the fact and parks — deliberately without returning, because
/// returning from a fault on an instruction that will fault again is an
/// infinite loop that looks like a hang. Core 0 is untouched and does the
/// talking.
///
/// The program counter is kept because a fault at the address of the read is
/// the wall, and a fault anywhere else is a bug in this experiment. Reporting
/// "it faulted" without saying where would make those two indistinguishable —
/// which is the failure exp154's own log ring was rescued from.
#[exception]
unsafe fn HardFault(ef: &ExceptionFrame) -> ! {
    FAULT_PC.store(ef.pc(), Ordering::Relaxed);
    FAULTED.store(true, Ordering::Relaxed);

    let sio = embassy_rp::pac::SIO;

    // Core 1 faulting is what this experiment is trying to cause, and core 0 is
    // still running to report it. Park quietly and let it.
    if sio.cpuid().read() != 0 {
        loop {
            cortex_m::asm::wfe();
        }
    }

    // Core 0 faulting is the case that has cost three flash cycles, because it
    // takes the executor, the log, the page and the heartbeat with it — and a
    // board that stops blinking looks exactly like a board that never started.
    //
    // So the handler drives the LED itself: bit-banged through SIO, with no
    // HAL, no executor and no interrupts, because those are precisely the
    // things that are no longer trustworthy here. Two quick flashes and a long
    // gap, which is not a rate anything else in this firmware produces —
    // **dark means never started, this pattern means died, and they were the
    // same signal until now.**
    let bit: u32 = 1 << 25;
    let n = LADDER.load(Ordering::Relaxed).max(1).min(12);
    loop {
        for _ in 0..n {
            sio.gpio_out(0).value().modify(|v| *v |= bit);
            cortex_m::asm::delay(15_000_000);
            sio.gpio_out(0).value().modify(|v| *v &= !bit);
            cortex_m::asm::delay(15_000_000);
        }
        cortex_m::asm::delay(150_000_000);
    }
}

/// What core 1 does.
///
/// **Three reads of one address**, with core 0 changing exactly one thing
/// between each pair, and that is the whole design:
///
/// ```text
///   read 1   Secure,     wall open    -> works   is this core alive at all?
///   read 2   Non-secure, wall open    -> works   can a demoted core execute?
///   read 3   Non-secure, wall shut    -> faults  ACCESSCTRL, and only ACCESSCTRL
/// ```
///
/// Read 1 to read 2 changes only the *security state*. Read 2 to read 3 changes
/// only the *ACCESSCTRL bits*. A version with just reads 1 and 3 changes both at
/// once and cannot say which did it — and that is not a hypothetical: the first
/// hardware run of this experiment did exactly that, and its "the wall is
/// there" could equally have meant "a Non-secure core cannot run".
///
/// Read 3 is last on purpose. It is the one expected to fault, and a faulted
/// core 1 parks in the handler forever, so anything after it would never
/// happen.
fn core1_main() -> ! {
    CORE1_STEP.store(STEP_ALIVE, Ordering::Relaxed);

    // Read one: Secure, nothing denied. If even this never lands, core 1 never
    // got going and nothing below has been measured.
    let secure = unsafe { core::ptr::read_volatile(target()) };
    CORE1_SECURE.store(secure, Ordering::Relaxed);
    CORE1_STEP.store(STEP_SECURE_READ, Ordering::Relaxed);

    // Wait for core 0 to open the wall and demote this core.
    while !GO_OPEN.load(Ordering::Relaxed) {
        cortex_m::asm::nop();
    }
    CORE1_STEP.store(STEP_ABOUT_TO_READ_OPEN, Ordering::Relaxed);

    // Read two: Non-secure, and permitted. This is the control that the first
    // hardware run did not have. If it faults, the finding is about
    // FORCE_CORE_NS and not about the wall at all.
    let open = unsafe { core::ptr::read_volatile(target()) };
    CORE1_OPEN.store(open, Ordering::Relaxed);
    CORE1_STEP.store(STEP_OPEN_READ, Ordering::Relaxed);

    // Wait for core 0 to shut the wall. Nothing else changes.
    while !GO_SHUT.load(Ordering::Relaxed) {
        cortex_m::asm::nop();
    }
    CORE1_STEP.store(STEP_ABOUT_TO_READ_SHUT, Ordering::Relaxed);

    // Read three: the one the wall exists to refuse.
    let shut = unsafe { core::ptr::read_volatile(target()) };
    CORE1_SHUT.store(shut, Ordering::Relaxed);
    CORE1_STEP.store(STEP_SHUT_READ, Ordering::Relaxed);

    loop {
        cortex_m::asm::wfe();
    }
}

/// Deny Non-secure access to the target peripheral, then make core 1
/// Non-secure.
///
/// The bits, because the PAC's own documentation cannot be read off the field
/// names here: every doc string in `accessctrl::regs::Access` describes the
/// field **after** the one it is attached to — `su` carries NSP's sentence,
/// `core1` carries CORE0's. The names and the bit positions are right and the
/// prose is off by one, so this code goes by position: NSU 0, NSP 1, SU 2,
/// SP 3, CORE0 4, CORE1 5, DMA 6, DBG 7.
///
/// Clearing NSU and NSP is the whole wall. SP stays set, which is what keeps
/// core 0's own read working — and that read is the control, so removing it
/// would remove the measurement rather than tightening it.
/// Take I2C1 out of reset, and wait until the hardware agrees it is out.
///
/// This is the line whose absence killed the first two builds, and it killed
/// them in the least readable way available. Peripherals on this chip come up
/// **held in reset**, and reading a register of one that is still in reset is a
/// bus fault — so the very first rung of the ladder, `read I2C1 from core 0
/// before any wall exists`, faulted on core 0, which is the core holding USB.
/// The board blinked three times (the three-second wait for enumeration) and
/// then went dark and silent, which reads exactly like a firmware that never
/// started.
///
/// The experiment's own README warned about putting a fault on the core that
/// does the talking. It was written about core 1, and then core 0 was handed a
/// read that could fault.
fn bring_i2c1_out_of_reset() {
    let r = embassy_rp::pac::RESETS;
    r.reset().modify(|w| w.set_i2c1(false));
    while !r.reset_done().read().i2c1() {
        cortex_m::asm::nop();
    }
}

/// The 16-bit key every ACCESSCTRL write needs, in bits 31:16.
///
/// **Measured, no longer a hypothesis.** Six rounds of this experiment saw an
/// identity write to `ACCESSCTRL.I2C1` — writing back the value just read, from
/// a Secure Privileged core — take a bus fault, while reads of the same
/// register worked. `rp-pac` models no key: `Access` is a `u32` with fields
/// only in bits 0..7, so `modify()` reads a register whose top half is zero and
/// writes zero back there, which is exactly the write that was refused.
///
/// With `0xACCE` in the top half the same write is accepted, on hardware, and
/// the register reads back what was written. That also explains the shape of
/// the earlier failure precisely: the block's own documentation says writes it
/// does not accept *raise a bus error* rather than being quietly dropped, which
/// is why a wrong key looked like a broken register instead of a no-op.
const ACCESSCTRL_KEY: u32 = 0xACCE_0000;

/// Every ACCESSCTRL write in this firmware goes through here.
///
/// Not tidiness: `modify()` is a read-modify-write and would drop the key on the
/// floor every time, so a helper that cannot forget it is the only safe shape.
fn accessctrl_write(reg: embassy_rp::pac::common::Reg<embassy_rp::pac::accessctrl::regs::Access, embassy_rp::pac::common::RW>, bits: u32) {
    reg.write_value(embassy_rp::pac::accessctrl::regs::Access(ACCESSCTRL_KEY | (bits & 0xFFFF)));
}

/// The two bits that are the wall: NSU (bit 0) and NSP (bit 1).
///
/// Everything else in the register is left exactly as the hardware had it. The
/// PAC's doc comments for `Access` are shifted by one field — `su` carries
/// NSP's sentence, `core1` carries CORE0's — so this code goes by bit position
/// and not by prose: NSU 0, NSP 1, SU 2, SP 3, CORE0 4, CORE1 5, DMA 6, DBG 7.
///
/// **The silicon settled which of the two readings was right.** I2C1 reads
/// `0x0000_00fc` at power-on: `nsu=0 nsp=0 su=1 sp=1 core0=1 core1=1 dma=1
/// dbg=1`, which is the register's documented default of "Secure access from
/// any master" exactly. The field *names and positions* are correct and it is
/// the doc comments that are misattached.
const NON_SECURE_BITS: u32 = 0b11;

/// Open the wall: let Non-secure code reach the peripheral.
///
/// This is the step the first hardware run did not have, and without it the
/// experiment cannot support its own claim. `0xfc` at power-on **already** had
/// NSU and NSP clear, so the "deny" write changed nothing and the Non-secure
/// read would have faulted whether this firmware ran or not. A wall you did not
/// build is not a wall you measured.
fn allow_non_secure(before: u32) {
    accessctrl_write(embassy_rp::pac::ACCESSCTRL.i2c1(), before | NON_SECURE_BITS);
}

/// Shut it again. One register write, and nothing else in the system changes
/// between core 1's second read and its third.
fn deny_non_secure(before: u32) {
    accessctrl_write(embassy_rp::pac::ACCESSCTRL.i2c1(), before & !NON_SECURE_BITS);
}

/// Demote core 1, as a separate step and **after** it is already running.
///
/// Whether demoting a core that is already executing works at all is a question
/// this experiment asks rather than assumes. If it does not, core 1's second
/// read simply succeeds and the log says so.
fn demote_core1() {
    let r = embassy_rp::pac::ACCESSCTRL.force_core_ns();
    let cur = r.read().0;
    r.write_value(embassy_rp::pac::accessctrl::regs::ForceCoreNs(
        ACCESSCTRL_KEY | ((cur | 0b10) & 0xFFFF),
    ));
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

#[embassy_executor::task]
async fn verdict_task(core1: embassy_rp::Peri<'static, embassy_rp::peripherals::CORE1>) -> ! {
    // Let USB enumerate before anything else happens.
    Timer::after(Duration::from_secs(3)).await;

    // Every step announces itself *before* it runs, so the last line in the log
    // names the thing that did not come back. A ladder like this costs one
    // flash cycle and answers which rung broke — which is the only thing worth
    // buying when each attempt needs somebody at a bench.
    LADDER.store(1, Ordering::Relaxed);
    log!("step 1: taking I2C1 out of reset. One still in reset faults when read.");
    bring_i2c1_out_of_reset();
    log!("step 1 ok.");

    LADDER.store(2, Ordering::Relaxed);
    log!("step 2: reading I2C1 from core 0, while no wall exists yet.");
    let baseline = unsafe { core::ptr::read_volatile(target()) };
    log!("step 2 ok: {:#010x}. What an unrestricted read looks like.", baseline);

    LADDER.store(3, Ordering::Relaxed);
    log!("step 3: launching core 1, still Secure.");
    #[allow(static_mut_refs)]
    let stack = unsafe { &mut CORE1_STACK };
    spawn_core1(core1, stack, core1_main);
    log!("step 3 ok: spawn_core1 returned; core 1 answered its handshake.");

    LADDER.store(4, Ordering::Relaxed);
    Timer::after(Duration::from_secs(1)).await;
    if CORE1_STEP.load(Ordering::Relaxed) >= STEP_SECURE_READ {
        log!(
            "step 4 ok: core 1 read {:#010x} while Secure. Same core, no wall yet.",
            CORE1_SECURE.load(Ordering::Relaxed)
        );
    } else {
        log!("step 4 PROBLEM: core 1 never completed a read. Nothing below is measured.");
    }

    // From here on **core 0 never touches that address again**, and that is the
    // point rather than tidiness. If the bits are wrong, the read that pays for
    // it must not be the one holding USB. Core 1's own earlier reads are the
    // controls — the same core and the same address, with exactly one thing
    // changed before each.
    //
    // The steps used to be two seconds apart, because for six rounds the only
    // instrument was somebody counting blinks before the board went dark. The
    // fault handler now blinks the rung number itself, so the spacing no longer
    // carries information and is down to half a second — enough that the log
    // orders unambiguously, and no longer a wait anybody sits through.
    LADDER.store(5, Ordering::Relaxed);
    log!("step 5: reading accessctrl.LOCK — is this block readable at all?");
    Timer::after(Duration::from_millis(500)).await;
    let lock = embassy_rp::pac::ACCESSCTRL.lock().read().0;
    SAW_LOCK.store(lock, Ordering::Relaxed);
    log!("step 5 ok: LOCK = {:#010x}. Bit 2 is DMA, set by the bootrom.", lock);

    LADDER.store(6, Ordering::Relaxed);
    log!("step 6: reading accessctrl.I2C1 — its power-on value.");
    Timer::after(Duration::from_millis(500)).await;
    let before = embassy_rp::pac::ACCESSCTRL.i2c1().read().0;
    SAW_BEFORE.store(before, Ordering::Relaxed);
    log!("step 6 ok: I2C1 access = {:#010x} at power-on.", before);
    log!(
        "  bits: nsu={} nsp={} su={} sp={} core0={} core1={} dma={} dbg={}",
        before & 1, (before >> 1) & 1, (before >> 2) & 1, (before >> 3) & 1,
        (before >> 4) & 1, (before >> 5) & 1, (before >> 6) & 1, (before >> 7) & 1
    );
    if before & NON_SECURE_BITS == 0 {
        log!("  Non-secure is ALREADY denied. We must OPEN the wall to prove we shut it.");
    }

    LADDER.store(7, Ordering::Relaxed);
    log!("step 7: identity write, with {:#010x} in the top half.", ACCESSCTRL_KEY);
    Timer::after(Duration::from_millis(500)).await;
    accessctrl_write(embassy_rp::pac::ACCESSCTRL.i2c1(), before);
    log!("step 7 ok: a keyed write is accepted. Without the key it faulted.");

    // Opening the wall is the step that turns a photograph into a measurement.
    LADDER.store(8, Ordering::Relaxed);
    log!("step 8: OPENING the wall - setting NSU and NSP, so Non-secure may read.");
    Timer::after(Duration::from_millis(500)).await;
    allow_non_secure(before);
    let opened = embassy_rp::pac::ACCESSCTRL.i2c1().read().0;
    SAW_OPENED.store(opened, Ordering::Relaxed);
    log!("step 8 ok: I2C1 access = {:#010x} (was {:#010x}).", opened, before);
    if opened == before {
        log!("  it did not change, so nothing below measures ACCESSCTRL.");
    }

    LADDER.store(9, Ordering::Relaxed);
    log!("step 9: FORCE_CORE_NS.CORE1 - demoting a core that is already running.");
    Timer::after(Duration::from_millis(500)).await;
    demote_core1();
    log!("step 9 ok.");

    LADDER.store(10, Ordering::Relaxed);
    log!("step 10: read two - Non-secure, wall OPEN. This one must work.");
    Timer::after(Duration::from_millis(500)).await;
    GO_OPEN.store(true, Ordering::Relaxed);
    Timer::after(Duration::from_millis(500)).await;

    let open_read_worked = CORE1_STEP.load(Ordering::Relaxed) >= STEP_OPEN_READ
        && !FAULTED.load(Ordering::Relaxed);
    if open_read_worked {
        log!(
            "step 10 ok: read two = {:#010x}. A demoted core still executes and reads.",
            CORE1_OPEN.load(Ordering::Relaxed)
        );
    } else {
        log!("step 10 PROBLEM: no Non-secure read completed with the wall open.");
        log!("  A finding about FORCE_CORE_NS, not the wall. Nothing below is a wall.");
    }

    if open_read_worked {
        LADDER.store(11, Ordering::Relaxed);
        log!("step 11: SHUTTING the wall - clearing NSU and NSP. Nothing else changes.");
        Timer::after(Duration::from_millis(500)).await;
        deny_non_secure(before);
        let shut = embassy_rp::pac::ACCESSCTRL.i2c1().read().0;
        SAW_SHUT.store(shut, Ordering::Relaxed);
        log!("step 11 ok: I2C1 access = {:#010x} (was {:#010x}).", shut, opened);

        LADDER.store(12, Ordering::Relaxed);
        log!("step 12: read three - Non-secure, wall SHUT. This one must fault.");
        Timer::after(Duration::from_millis(500)).await;
        GO_SHUT.store(true, Ordering::Relaxed);
    }

    Timer::after(Duration::from_secs(1)).await;

    loop {
        let step = CORE1_STEP.load(Ordering::Relaxed);
        let faulted = FAULTED.load(Ordering::Relaxed);
        let pc = FAULT_PC.load(Ordering::Relaxed);
        let secure = CORE1_SECURE.load(Ordering::Relaxed);
        let open = CORE1_OPEN.load(Ordering::Relaxed);

        // The three reads, printed every time and whatever the outcome.
        //
        // They used to be printed only inside the branch where the experiment
        // passed, which made them decoration: a control you can only see when
        // the thing succeeded is not a control, and `check.sh` grepping for one
        // is a check that cannot fail. [exp140](../exp140-a-checksum-that-passes/)
        // is this repository's name for that mistake.
        log!(
            "  LOCK = {:#010x}, I2C1 at power-on = {:#010x}",
            SAW_LOCK.load(Ordering::Relaxed), SAW_BEFORE.load(Ordering::Relaxed)
        );
        log!(
            "  I2C1 opened to {:#010x}, then shut to {:#010x}",
            SAW_OPENED.load(Ordering::Relaxed), SAW_SHUT.load(Ordering::Relaxed)
        );
        if step >= STEP_SECURE_READ {
            log!("  read 1  Secure,     wall open: {:#010x}", secure);
        } else {
            log!("  read 1  Secure,     wall open: not taken (core 1 at step {})", step);
        }
        if step >= STEP_OPEN_READ {
            log!("  read 2  Non-secure, wall open: {:#010x}", open);
        } else {
            log!("  read 2  Non-secure, wall open: not taken (core 1 at step {})", step);
        }
        if step >= STEP_SHUT_READ {
            log!("  read 3  Non-secure, wall shut: {:#010x}", CORE1_SHUT.load(Ordering::Relaxed));
        } else if faulted && step == STEP_ABOUT_TO_READ_SHUT {
            log!("  read 3  Non-secure, wall shut: bus fault at pc {:#010x}", pc);
        } else {
            log!("  read 3  Non-secure, wall shut: not taken (core 1 at step {})", step);
        }

        match (step, faulted) {
            // The whole experiment, in one shape: three reads, one core, one
            // address, one thing changed at a time.
            (STEP_ABOUT_TO_READ_SHUT, true) => {
                log!("VERDICT: the wall is there. Only ACCESSCTRL changed between reads 2 and 3.");
            }
            (STEP_SHUT_READ, _) => {
                log!("VERDICT: NO WALL. ACCESSCTRL was written, read back, and did not refuse.");
            }
            (STEP_ABOUT_TO_READ_OPEN, true) => {
                log!("VERDICT: inconclusive, and about FORCE_CORE_NS, not the wall. See read 2.");
            }
            (STEP_OPEN_READ, false) => {
                log!("core 1 has not taken read three yet. Still waiting, no verdict.");
            }
            (STEP_SECURE_READ, false) => {
                log!("core 1 has not taken read two yet. Still waiting, no verdict.");
            }
            (STEP_NONE, _) | (STEP_ALIVE, false) => {
                log!("core 1 stopped at step {} without reading. Nothing was measured.", step);
            }
            (_, true) => {
                log!("a fault at pc {:#010x}, but core 1 was at step {}.", pc, step);
                log!("VERDICT: inconclusive — that fault is not the read.");
            }
            _ => {
                log!("core 1 at step {}, no fault. Inconclusive.", step);
            }
        }

        Timer::after(Duration::from_secs(10)).await;
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let p = embassy_rp::init(Default::default());
    let mut led = Output::new(p.PIN_25, Level::Low);

    // USB first, and everything that could go wrong after it.
    //
    // The first version of this experiment did the opposite — wall, core 1,
    // then USB — and the board went silent with no way to say why. Nothing
    // that can hang may run before the thing that reports. `verdict_task`
    // owns the rest of the sequence and speaks between every step.
    let driver = Driver::new(p.USB, Irqs);

    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some("exp156 a wall you can measure");
    config.serial_number = Some("156");
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

    let class = CdcAcmClass::new(&mut builder, ACM_STATE.init(State::new()), 64);
    let usb = builder.build();
    spawner.spawn(usb_task(usb).unwrap());

    let (sender, receiver, control) = class.split_with_control();
    spawner.spawn(reboot_task(control, receiver).unwrap());
    spawner.spawn(log_task(sender).unwrap());

    log!("exp156 up. No cryptography here, only whether an address refuses.");
    spawner.spawn(verdict_task(p.CORE1).unwrap());

    // Slow while waiting, fast once there is a verdict — the same one bit
    // exp154 put on the LED, for a reader with no page open.
    //
    // The heartbeat is logged every tenth beat and not every one, and that is a
    // bug fix rather than tidying. `usb-log`'s outgoing queue is sixteen lines
    // deep, it drops the newest when full, and nothing drains it until a host
    // asserts DTR — so a firmware that logs once a second has filled the queue
    // before anybody has opened the port. The first successful run of this
    // experiment lost exactly three lines that way, and they were the three the
    // run existed to produce: the power-on value of `ACCESSCTRL.I2C1` and its
    // bit breakdown. **The instrument ate the finding**, and it did it silently,
    // to the only lines nobody could reconstruct.
    let mut beat: u32 = 0;
    loop {
        let decided = FAULTED.load(Ordering::Relaxed)
            || CORE1_STEP.load(Ordering::Relaxed) == STEP_SHUT_READ;
        let (on, off) = if decided { (100, 100) } else { (50, 950) };

        led.set_high();
        Timer::after(Duration::from_millis(on)).await;
        led.set_low();
        if !decided {
            beat += 1;
            if beat % 10 == 0 {
                log!("heartbeat #{}", beat);
            }
        }
        Timer::after(Duration::from_millis(off)).await;
    }
}
