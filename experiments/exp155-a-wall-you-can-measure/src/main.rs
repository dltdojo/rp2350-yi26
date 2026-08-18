//! exp155 — a wall you can measure.
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
//!   core 0  Secure, privileged        core 1  Non-secure (FORCE_CORE_NS)
//!   -----------------------------     -----------------------------------
//!   owns USB, prints everything
//!   denies I2C1 to Non-secure   --->
//!   reads I2C1                        reads I2C1
//!     -> a value                        -> BusFault -> HardFault
//!   reports both                      handler sets a flag and parks
//! ```
//!
//! **The experiment passes only if both halves happen.** A Non-secure read that
//! faults, on its own, could be a broken core. A Secure read that works, on its
//! own, proves nothing about anybody else. The control is not decoration here;
//! it is half the measurement.
//!
//! # What it does not touch
//!
//! Nothing is locked. `ACCESSCTRL.LOCK` makes a configuration permanent until
//! reset and this never writes it, so a board that ends up in a state you did
//! not want is one power cycle from being ordinary again.
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
/// number it saw. A run that ends at 2 is a wall; one that ends at 0 is a core
/// that never started, and those look identical from the outside otherwise.
const STEP_NONE: u32 = 0;
const STEP_ALIVE: u32 = 1;
const STEP_ABOUT_TO_READ: u32 = 2;
const STEP_READ_RETURNED: u32 = 3;

static CORE1_STEP: AtomicU32 = AtomicU32::new(STEP_NONE);
static CORE1_VALUE: AtomicU32 = AtomicU32::new(0);
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
    loop {
        cortex_m::asm::wfe();
    }
}

/// What core 1 does, in Non-secure state.
///
/// Reads the one address, and is expected not to come back from it.
fn core1_main() -> ! {
    CORE1_STEP.store(STEP_ALIVE, Ordering::Relaxed);

    // A moment, so core 0's report cannot be a race: it should be able to
    // observe "alive" separately from whatever happens next.
    cortex_m::asm::delay(150_000_000);

    CORE1_STEP.store(STEP_ABOUT_TO_READ, Ordering::Relaxed);

    // The read the wall exists to refuse. `read_volatile` because the whole
    // point is that the access happens — an optimiser entitled to drop it
    // would turn this experiment into one that proves nothing quietly.
    let v = unsafe { core::ptr::read_volatile(target()) };

    // Only reached if the wall is not there.
    CORE1_VALUE.store(v, Ordering::Relaxed);
    CORE1_STEP.store(STEP_READ_RETURNED, Ordering::Relaxed);

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
fn build_the_wall() {
    let ac = embassy_rp::pac::ACCESSCTRL;

    ac.i2c1().modify(|w| {
        w.set_nsu(false);
        w.set_nsp(false);
        w.set_su(true);
        w.set_sp(true);
        w.set_core0(true);
        w.set_core1(true);
    });

    // Core 1 comes up Non-secure from here on. Core 0 is unaffected: there is
    // no bit in this register for it, which is the chip declining to offer a
    // way to lock its own boot core out.
    ac.force_core_ns().modify(|w| w.set_core1(true));
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
async fn verdict_task() -> ! {
    // Let USB enumerate before anything else happens. exp113 paid for this
    // lesson and exp154 inherited it: the first moments after boot are the one
    // window where a busy or crashed executor cannot be recovered over USB.
    Timer::after(Duration::from_secs(3)).await;

    log!("the wall: I2C1 denied to Non-secure, core 1 forced Non-secure.");

    // -- the control, first --------------------------------------------------
    //
    // Core 0 is Secure and privileged, and SP is set, so this must work. If it
    // does not, the experiment is over before it starts and says so: a wall
    // that blocks everybody is not a wall, it is a broken peripheral.
    let secure_read = unsafe { core::ptr::read_volatile(target()) };
    log!("core 0 (Secure) read {:#010x} from I2C1 IC_COMP_TYPE.", secure_read);
    if secure_read == 0 {
        log!("control FAILED: the Secure read returned zero. Nothing below means anything.");
    }

    // -- and then what happened on the other side ----------------------------
    Timer::after(Duration::from_secs(3)).await;

    loop {
        let step = CORE1_STEP.load(Ordering::Relaxed);
        let faulted = FAULTED.load(Ordering::Relaxed);
        let pc = FAULT_PC.load(Ordering::Relaxed);

        match (step, faulted) {
            (STEP_ABOUT_TO_READ, true) => {
                log!("core 1 (Non-secure) faulted at pc {:#010x} on that same address.", pc);
                log!("VERDICT: the wall is there. Readable from Secure, refused from Non-secure.");
            }
            (STEP_READ_RETURNED, _) => {
                log!(
                    "core 1 (Non-secure) read {:#010x} — no fault.",
                    CORE1_VALUE.load(Ordering::Relaxed)
                );
                log!("VERDICT: NO WALL. Non-secure read the same address Secure did.");
            }
            (STEP_ALIVE, false) => {
                log!("core 1 is alive and has not reached the read. Still waiting.");
            }
            (STEP_NONE, _) => {
                log!("core 1 never started. Nothing was measured — this is not a wall.");
            }
            (_, true) => {
                log!("a fault at pc {:#010x}, but core 1 was at step {} — not the read.", pc, step);
                log!("VERDICT: inconclusive. That fault is a bug in this experiment.");
            }
            _ => {
                log!("core 1 at step {}, no fault. Inconclusive.", step);
            }
        }

        // Repeating, because exp154 measured what printing once costs: 73 lines
        // went into a ring nobody was draining and a phone that attached later
        // saw a verdict box with nothing in it.
        Timer::after(Duration::from_secs(10)).await;
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let p = embassy_rp::init(Default::default());
    let mut led = Output::new(p.PIN_25, Level::Low);

    // Before core 1 exists, because it decides what core 1 will be.
    build_the_wall();

    #[allow(static_mut_refs)]
    let stack = unsafe { &mut CORE1_STACK };
    spawn_core1(p.CORE1, stack, core1_main);

    let driver = Driver::new(p.USB, Irqs);

    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some("exp155 a wall you can measure");
    config.serial_number = Some("155");
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

    log!("exp155 up. No cryptography here — only whether an address refuses.");
    spawner.spawn(verdict_task().unwrap());

    // Slow while waiting, fast once there is a verdict — the same one bit
    // exp154 put on the LED, for a reader with no page open.
    let mut beat: u32 = 0;
    loop {
        let decided = FAULTED.load(Ordering::Relaxed)
            || CORE1_STEP.load(Ordering::Relaxed) == STEP_READ_RETURNED;
        let (on, off) = if decided { (100, 100) } else { (50, 950) };

        led.set_high();
        Timer::after(Duration::from_millis(on)).await;
        led.set_low();
        if !decided {
            beat += 1;
            log!("heartbeat #{}", beat);
        }
        Timer::after(Duration::from_millis(off)).await;
    }
}
