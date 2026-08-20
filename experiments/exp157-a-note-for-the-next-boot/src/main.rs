//! exp157 — a note for the next boot.
//!
//! [exp156](../exp156-a-wall-you-can-measure/) took seven flash cycles, each one
//! somebody's walk to a bench, and **two of them produced a fact about the
//! subject**. Two went on making the experiment run at all. Two went on making
//! the LED able to say *where* it died rather than *that* it died. One was lost
//! to a report that said "it kept blinking" when slow and fast mean different
//! things.
//!
//! [`docs/the-board-is-the-loop.md`](../../docs/the-board-is-the-loop.md) does
//! that arithmetic. This experiment builds the first thing it asks for.
//!
//! # The claim
//!
//! > **A firmware killed in a way that takes USB and the log with it comes back
//! > and says which step it died in — and says which kind of death it was.**
//!
//! Two kinds, because they are the two that happen and they had been
//! indistinguishable:
//!
//! - a **hang**, which is what exp156's first round actually was
//!   (`spawn_core1` waiting on a core that could not answer). No exception
//!   fires. The board simply stops, and darkness is also what a firmware that
//!   never started looks like.
//! - a **fault**, which is what its later rounds were.
//!
//! # It has to be able to fail, or it has proved nothing
//!
//! A harness that always answers "step 3" cannot be caught being wrong, and
//! [exp140](../exp140-a-checksum-that-passes/) is this repository's name for
//! that mistake. So the run kills itself **at different steps, in different
//! ways**, and the report has to name each correctly:
//!
//! ```text
//!   boot 1   runs all eight steps and finishes      -> the control
//!   boot 2   HANGS at step 3                        -> reported as hang, step 3
//!   boot 3   FAULTS at step 6                       -> reported as fault, step 6
//!   boot 4   runs all eight steps and finishes      -> recovery is not damage
//!   boot 5   stops, and reports the whole history for as long as it is on
//! ```
//!
//! The control is not decoration. Without boot 1 and boot 4, "it says where it
//! died" is indistinguishable from "it always says something died", and a
//! firmware that can only report failure cannot report success.
//!
//! # Why the fault is a peripheral in reset
//!
//! Because this repository already measured that one. exp156's second build
//! died on it: **peripherals come up held in reset, and reading a register of
//! one that still is faults.** I2C1 is untouched by this firmware, so reading it
//! is a fault generator with no ambiguity and nothing to configure.
//!
//! # The safety property
//!
//! After boot 5 nothing is armed and nothing is retried. A board in a reboot
//! loop it cannot be talked out of is worse than the slow loop this replaces:
//! the 1200-baud reflash touch needs the device to stay enumerated long enough
//! to hear it. Measured — after the storm the board is still `running`, still
//! enumerated, and still enters BOOTSEL with nobody near the button.
//!
//! **And it keeps talking after it stops.** A spike written before this
//! experiment fell silent at its limit, and a reader arriving a moment later saw
//! a blinking LED and nothing else — which is exactly the state exp156's round
//! seven could not diagnose.

#![no_std]
#![no_main]

use core::sync::atomic::{AtomicBool, Ordering};

use breadcrumb::Cause;
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

/// How long a step may take before the watchdog calls it a hang.
///
/// Longer than any step that is expected to succeed, or the harness reports a
/// death that never happened — which is a worse failure than reporting none,
/// because it is believable.
const STEP_BUDGET_US: u32 = 2_000_000;

/// The scripted deaths. Different steps and different kinds, so a harness that
/// always said the same thing would be caught.
const HANG_BOOT: u32 = 2;
const HANG_STEP: u8 = 3;
const FAULT_BOOT: u32 = 3;
const FAULT_STEP: u8 = 6;

/// After this the board stops arming anything and only reports.
const LAST_BOOT: u32 = 5;

const STEPS: u8 = 8;

/// How long every boot stays enumerated with nothing armed, before it risks
/// anything. The escape hatch: a board that always has a quiet window is a board
/// the host can always reach.
const REFLASH_WINDOW_S: u64 = 6;

/// The USB control buffer, and the product string that has to fit inside it.
///
/// **This pair cost two board recoveries by hand.** The first build called
/// itself `"exp157 a note for the next boot"` — thirty-one characters — and the
/// board enumerated far enough to hand over its device and configuration
/// descriptors and then froze. No log, no LED, no reboot: `urbnum` stopped
/// advancing, `bConfigurationValue` stayed empty, and the board looked exactly
/// like a firmware that had bricked itself.
///
/// It had. `embassy-usb` builds string descriptors *into the control buffer*,
/// and asserts once per UTF-16 unit:
///
/// ```text
///     assert!(pos + 2 < buf.len(), "control buffer too small");
/// ```
///
/// The last character of a 31-character string needs `64 < 64`, which is false,
/// so it panics — inside the USB stack, before enumeration finishes, with
/// `panic_halt` as the panic handler. The executor stops. **Nothing is left that
/// can say so**, which is why two rounds were spent diagnosing the watchdog.
///
/// `<` and not `<=`, so the limit is one shorter than the arithmetic suggests:
/// with a 64-byte buffer a product name may be **30 characters**, not 31.
///
/// So it is a build failure now. A `const` assertion costs nothing, fires on
/// every `cargo build`, and cannot be forgotten — which is what
/// [`docs/the-board-is-the-loop.md`](../../docs/the-board-is-the-loop.md) means
/// by testing what needs no board before spending a trip.
const CONTROL_BUF_LEN: usize = 64;
const PRODUCT: &str = "exp157 note for the next boot";
const _: () = assert!(
    2 * PRODUCT.len() + 2 < CONTROL_BUF_LEN,
    "product string will overflow embassy-usb's control buffer and panic mid-enumeration"
);

/// Where the fault comes from: an undefined instruction.
///
/// The first version of this read a peripheral "still held in reset", because
/// exp156 records dying that way and it looked like a fault generator this
/// repository had already measured. **It did not fault**, and the run said so —
/// boot 3 completed all eight steps where a fault was scripted.
///
/// The reason is one line in `embassy-rp`: `init()` calls `clocks::init()`,
/// which ends with `reset::unreset_wait(ALL_PERIPHERALS)`. **Every peripheral is
/// out of reset before any experiment's own code runs**, so there is no such
/// thing as reading one in reset from inside an embassy firmware — and exp156's
/// `bring_i2c1_out_of_reset()` is a no-op that its `check.sh` guards.
///
/// `udf` needs no peripheral, no address and no assumption: it is an undefined
/// instruction, so it raises a UsageFault that escalates to HardFault, on every
/// Cortex-M, every time.
#[inline(always)]
fn make_it_fault() -> ! {
    cortex_m::asm::udf()
}

/// Turn a fault into a reboot that the next boot can describe.
///
/// The alternative is what exp156 does: park, and drive the LED by hand so
/// somebody can count flashes. That was the right answer when nothing survived
/// the death. This one hands the step number to the next boot instead, and no
/// one has to count anything.
#[exception]
unsafe fn HardFault(_ef: &ExceptionFrame) -> ! {
    breadcrumb::reboot()
}

/// Set once the storm is over, so the LED rate says which state the board is in.
static STOPPED: AtomicBool = AtomicBool::new(false);

/// The LED, driven from the first moment there is one.
///
/// exp156's hardest-won rule — *bring the LED up before anything that can
/// hang* — and this experiment did not follow it. Its first two builds froze
/// inside the USB stack with the LED dark, so "never started" and "died during
/// enumeration" were the same signal, and two board recoveries went on telling
/// them apart. A heartbeat that starts before `Driver::new` answers that for
/// free.
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

fn cause_name(c: Cause) -> &'static str {
    match c {
        Cause::Fresh => "fresh",
        Cause::Completed => "completed",
        Cause::Hang => "HANG",
        Cause::Fault => "FAULT",
    }
}

/// Everything the run has established so far, printed on a loop.
///
/// Not tidiness. A fact printed once is a fact most readers never see, and
/// somebody attaching late is the normal case rather than the exception —
/// especially here, where the interesting part is over in half a minute.
fn report(note: &breadcrumb::Note) {
    if note.cause == Cause::Fresh {
        log!("boot #{} — nothing before it. Fresh flash or power-on.", note.boot);
    } else {
        log!("boot #{}, and the boot before it {}.", note.boot, cause_name(note.cause));
    }
    for n in 1..=breadcrumb::HISTORY as u32 {
        match note.ended(n) {
            Some((Cause::Completed, _)) => log!("  boot {}: completed all {} steps", n, STEPS),
            Some((c, step)) => log!("  boot {}: {} in step {}", n, cause_name(c), step),
            None => {}
        }
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    // FIRST, before anything else can touch a register or take a fault.
    let note = breadcrumb::read();

    let p = embassy_rp::init(Default::default());

    // Before the USB stack, on purpose. Everything that has gone wrong in this
    // experiment went wrong inside or before enumeration, with nothing able to
    // report it.
    spawner.spawn(heartbeat(Output::new(p.PIN_25, Level::Low)).unwrap());

    let driver = Driver::new(p.USB, Irqs);
    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some(PRODUCT);
    config.serial_number = Some("157");
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

    // Report before risk, always. Whatever this boot goes on to do, the previous
    // boot's death is out of the building first.
    Timer::after(Duration::from_secs(3)).await;
    log!("exp157 up. What the previous boot left behind:");
    report(&note);

    if note.boot >= LAST_BOOT {
        // The stop, and it is the whole safety property. Nothing armed, nothing
        // retried, and the board stays reflashable from the host.
        breadcrumb::disarm();
        STOPPED.store(true, Ordering::Relaxed);

        // The STOP line repeats with the rest, and that is not decoration: it is
        // the safety property, and a safety property printed once is one that
        // most readers never see. `check.sh` caught this by failing on a board
        // that was working perfectly — it had arrived after the only mention.
        loop {
            report(&note);
            log!("STOP after {} boots. Nothing armed; still reflashable.", note.boot);
            log!("VERDICT: two deaths, two kinds, two steps, named above.");
            Timer::after(Duration::from_secs(10)).await;
        }
    }

    // A window with nothing armed, before anything can reboot the board.
    //
    // Insurance bought the expensive way. The first version of this experiment
    // left an armed watchdog running into the next boot, which cut that boot
    // down before USB finished enumerating — and a board that never finishes
    // enumerating cannot hear the 1200-baud reflash touch, so it came back only
    // by hand, on the BOOTSEL button.
    //
    // `breadcrumb::read` disarming on entry is the fix for that. This is the
    // belt to its braces: however badly the sequence below behaves, every boot
    // spends this long enumerated and quiet, and `yi26 bootsel` lands.
    log!("reflash window: {} s with nothing armed. `yi26 bootsel` works now.", REFLASH_WINDOW_S);
    Timer::after(Duration::from_secs(REFLASH_WINDOW_S)).await;

    log!("this boot: running {} steps, budget {} ms each.", STEPS, STEP_BUDGET_US / 1000);
    breadcrumb::arm(STEP_BUDGET_US);

    for n in 1..=STEPS {
        // Before the step, never after. The number that survives has to name the
        // step that did not come back.
        breadcrumb::step(n);
        breadcrumb::feed(STEP_BUDGET_US);
        log!("  step {}", n);

        if note.boot == HANG_BOOT && n == HANG_STEP {
            log!("  hanging on purpose. Nothing feeds the watchdog from here.");
            // Not a fault. No handler runs. This is exp156 round one exactly.
            loop {
                cortex_m::asm::nop();
            }
        }

        if note.boot == FAULT_BOOT && n == FAULT_STEP {
            log!("  faulting on purpose: an undefined instruction.");
            Timer::after(Duration::from_millis(80)).await;
            make_it_fault();
        }

        Timer::after(Duration::from_millis(120)).await;
    }

    // Say so, or a boot that finished looks exactly like one that died in its
    // last step — and a report that cannot say "nothing went wrong" is a report
    // whose failures mean nothing.
    breadcrumb::finished();
    log!("all {} steps done. Going round again to run the next case.", STEPS);
    Timer::after(Duration::from_millis(300)).await;
    breadcrumb::reboot()
}
