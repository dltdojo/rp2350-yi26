//! exp158 — four keys and one flash.
//!
//! [exp156](../exp156-a-wall-you-can-measure/) spent **three separate bench
//! trips** on one question: `ACCESSCTRL` reads fine and refuses every write, so
//! what does a write need? Round five found it was the write. Round six found
//! that *any* write faults, including writing back the value just read. Round
//! seven proposed a key. Three flashes, three walks to a board, one bit each.
//!
//! This asks the whole question in **one flash**, and the board does the
//! walking:
//!
//! ```text
//!   boot 1   key 0x0000   ->  faults. Marked, and stepped over.
//!   boot 2   key 0x5afe   ->  faults. Marked, and stepped over.
//!   boot 3   key 0xacce   ->  survives, and the register changes.
//!   boot 4   key 0xdead   ->  faults. Marked.
//!   boot 5   nothing left to try. Reports all four, forever.
//! ```
//!
//! [exp157](../exp157-a-note-for-the-next-boot/) made a dead run able to file a
//! report. This is the half that uses it: **a boot that comes back after a death
//! does not retry the thing that killed it.** It marks that candidate as tried
//! and attempts the next one, so a list a human would walk one trip at a time is
//! walked by the board while nobody is watching.
//!
//! # Why this payload, and not something harmless
//!
//! **Because the answer is already known.** exp156 measured, on hardware, that
//! `0xACCE` in bits 31:16 is accepted and that a write without it faults. So a
//! harness that mislabels a candidate, or that quietly retries one, or that
//! reports a plausible table it did not actually measure, **gets caught** — the
//! run has a right answer to be wrong about.
//!
//! A synthetic matrix would demonstrate the mechanism and prove nothing about
//! whether it replaces a human round, which is the only claim worth making here.
//! [exp140](../exp140-a-checksum-that-passes/) is what this repository calls a
//! check that cannot fail.
//!
//! # What it does to the board
//!
//! Each candidate does one thing: read `ACCESSCTRL.I2C1`, write it back with
//! **NSU and NSP set** using that candidate's key, read it again, and then put
//! the original value back **using the same candidate's key**. Restoring with
//! the candidate's own key rather than with the known-good one matters: it keeps
//! each candidate self-contained and stops the answer being smuggled into the
//! test.
//!
//! A candidate is *accepted* only if the register actually changed. Surviving is
//! not enough — a write that is silently ignored also survives, and telling
//! those apart is the whole question.
//!
//! **`ACCESSCTRL.LOCK` is never written.** It survives until reset with no
//! software undo; `check.sh` greps for that rather than trusting this sentence.
//! Everything else here is one power cycle from ordinary.

#![no_std]
#![no_main]

use core::sync::atomic::{AtomicBool, Ordering};

use cortex_m_rt::{exception, ExceptionFrame};
use embassy_executor::Spawner;
use embassy_rp::bind_interrupts;
use embassy_rp::gpio::{Level, Output};
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

/// The candidates, in the order the board will try them.
///
/// `0xACCE` is deliberately **third**, not first. The run has to come back from
/// two deaths before it reaches the answer, and then carry on past a success to
/// a fourth candidate — so stepping over a death and stepping over a win are
/// both exercised, and neither can be the accident that makes it look right.
const KEYS: [u16; 4] = [0x0000, 0x5AFE, 0xACCE, 0xDEAD];

/// Bits 0 and 1 of an `Access` register: NSU and NSP.
///
/// Setting them is a change this experiment can *see*, which is what separates
/// an accepted write from an ignored one. exp156 measured I2C1's power-on value
/// as `0x0000_00fc` — both bits clear — so setting them is always a real change
/// on a board that has not been fiddled with.
const NON_SECURE_BITS: u32 = 0b11;

/// Longer than any candidate needs. A budget shorter than a step that was going
/// to succeed reports a death that never happened, which is worse than reporting
/// none because it is believable.
const STEP_BUDGET_US: u32 = 2_000_000;

/// Stop after this many boots whatever happens. Four candidates plus the boot
/// that reports them is five; anything beyond that means something is retrying,
/// and a board that reboots forever cannot be reflashed.
const LAST_BOOT: u32 = 8;

/// Seconds each boot spends enumerated with nothing armed, before it risks
/// anything. The escape hatch, and exp157 paid two bench trips for it.
const REFLASH_WINDOW_S: u64 = 5;

/// `embassy-usb` builds string descriptors into the control buffer and asserts
/// `pos + 2 < buf.len()` per UTF-16 unit, so 64 bytes means **30 characters**,
/// not 31. At 31 it panics mid-enumeration and `panic_halt` stops the executor:
/// no log, no LED, no reboot, and a board that looks bricked. exp157 lost two
/// board recoveries to it. A build failure costs nothing.
const CONTROL_BUF_LEN: usize = 64;
const PRODUCT: &str = "exp158 four keys, one flash";
const _: () = assert!(
    2 * PRODUCT.len() + 2 < CONTROL_BUF_LEN,
    "product string will overflow embassy-usb's control buffer and panic mid-enumeration"
);

static STOPPED: AtomicBool = AtomicBool::new(false);

/// Every ACCESSCTRL write in this firmware goes through here.
///
/// `rp-pac` models no key — `Access` has fields only in bits 0..7 — so
/// `modify()` is a read-modify-write that puts zero in the top half every time,
/// which is exactly the write exp156 measured taking a bus fault. A helper that
/// cannot forget the key is the only safe shape, and here the key is a variable
/// because the key is the question.
fn accessctrl_write(bits: u32, key: u16) {
    embassy_rp::pac::ACCESSCTRL
        .i2c1()
        .write_value(embassy_rp::pac::accessctrl::regs::Access(
            ((key as u32) << 16) | (bits & 0xFFFF),
        ));
}

fn i2c1_access() -> u32 {
    embassy_rp::pac::ACCESSCTRL.i2c1().read().0
}

/// Turn a fault into a reboot the next boot can describe.
#[exception]
unsafe fn HardFault(_ef: &ExceptionFrame) -> ! {
    breadcrumb::reboot()
}

/// Slow while the matrix is being walked, fast once it is done.
///
/// Started before the USB stack, because everything that has gone wrong on this
/// track went wrong inside or before enumeration with nothing able to say so.
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

/// The whole table, printed on a loop.
///
/// Every finding lives in the block that repeats. A fact printed once is a fact
/// most readers never see, and here the interesting part is over in under a
/// minute — so arriving late costs the narrative and none of the results.
fn report(note: &breadcrumb::Note) {
    let mut accepted = 0u8;
    for (i, key) in KEYS.iter().enumerate() {
        let n = i as u8 + 1;
        match note.outcome(n) {
            breadcrumb::NOT_ATTEMPTED => log!("  key {:#06x}  not tried yet", key),
            breadcrumb::DIED => log!("  key {:#06x}  DIED - the write faulted", key),
            breadcrumb::SURVIVED_A => {
                accepted += 1;
                log!("  key {:#06x}  ACCEPTED - the register changed", key);
            }
            _ => log!("  key {:#06x}  ignored - survived, no effect", key),
        }
    }
    log!("  {} of {} keys accepted.", accepted, KEYS.len());
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    // FIRST, before anything can touch a register or take a fault.
    let note = breadcrumb::read();

    let p = embassy_rp::init(Default::default());
    spawner.spawn(heartbeat(Output::new(p.PIN_25, Level::Low)).unwrap());

    let driver = Driver::new(p.USB, Irqs);
    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some(PRODUCT);
    config.serial_number = Some("158");
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
    log!("exp158 up, boot #{}. The matrix so far:", note.boot);
    report(&note);

    let next = note.next_unattempted(KEYS.len() as u8);

    if next.is_none() || note.boot >= LAST_BOOT {
        breadcrumb::disarm();
        STOPPED.store(true, Ordering::Relaxed);
        loop {
            log!("exp158 done after {} boots. Nothing armed; still reflashable.", note.boot);
            report(&note);
            log!("VERDICT: the board walked four candidates in one flash.");
            Timer::after(Duration::from_secs(10)).await;
        }
    }

    let n = next.unwrap();
    let key = KEYS[(n - 1) as usize];

    log!("reflash window: {} s, nothing armed. `yi26 bootsel` works now.", REFLASH_WINDOW_S);
    Timer::after(Duration::from_secs(REFLASH_WINDOW_S)).await;

    // From here a death is ours, and the next boot will step over this one.
    breadcrumb::arm(STEP_BUDGET_US);
    breadcrumb::step(n);

    let before = i2c1_access();
    log!("candidate {}: key {:#06x}. I2C1 reads {:#010x}.", n, key, before);
    Timer::after(Duration::from_millis(200)).await;

    // The write that either faults, changes the register, or is ignored.
    accessctrl_write(before | NON_SECURE_BITS, key);
    let after = i2c1_access();

    // Still here, so it did not fault. Put it back with the SAME key, so nothing
    // in this test depends on knowing the answer in advance.
    accessctrl_write(before, key);

    if after != before {
        log!("  survived, and {:#010x} -> {:#010x}. ACCEPTED.", before, after);
        breadcrumb::mark(n, breadcrumb::SURVIVED_A);
    } else {
        log!("  survived, but nothing changed. Ignored, not accepted.");
        breadcrumb::mark(n, breadcrumb::SURVIVED_B);
    }

    breadcrumb::finished();
    Timer::after(Duration::from_millis(300)).await;
    breadcrumb::reboot()
}
