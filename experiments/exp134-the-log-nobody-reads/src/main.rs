//! exp134 — what a log should keep while nobody is reading it.
//!
//! This firmware does almost nothing: it prints one numbered line every
//! second, forever. The experiment is not the firmware. It is the *same*
//! firmware built three times against three different queue policies, left
//! alone for longer than its queue can hold, and then read.
//!
//! # Where this came from
//!
//! From a capture in exp127, taken on a phone. Between one line and the next
//! the log jumped a hundred and twenty-five seconds and said
//! `(+50 lines lost)`. Two minutes of a board's life were gone — and they were
//! the two minutes somebody had just spent operating it, because the gap ends
//! at the moment they connected. The same shape appeared in exp130 (`+64`) and
//! exp133 (`+89`).
//!
//! The obvious diagnosis is that [`usb_log::QUEUE_DEPTH`] is too small, and it
//! is wrong. Sixteen lines at one per second is sixteen seconds; sixty-four
//! would be a minute. The gap is however long nobody was looking, which has no
//! upper bound, so no depth wins. Four times the RAM buys four times a number
//! that was never going to be enough.
//!
//! # The question that was actually being dodged
//!
//! `usb-log`'s own documentation said there were "only two choices": wait for
//! room, or drop the line. Waiting is genuinely disqualified — exp104 measured
//! two counter values arriving 21 seconds apart when the caller was parked
//! inside `write_all`. But dropping hides a second question that nobody had
//! asked in thirty-three experiments:
//!
//! **which** line?
//!
//! `Channel::try_send` refuses the *new* arrival, so a full queue preserves
//! the *oldest* sixteen lines. That is not a decision anybody made; it is what
//! the container does, adopted by default. The alternative — evict the head,
//! keep the newest sixteen — costs the same RAM and the same time, and hands a
//! late reader a completely different log.
//!
//! And there is a third answer that is not about fullness at all: while no
//! host has the port open, queue **nothing**. Count everything, keep none of
//! it, and guarantee that the first line a reader ever sees describes the
//! present rather than a fossil.
//!
//! # What each one leaves you
//!
//! Ten lines into a queue of three, with nobody reading, from
//! [`log_policy`]'s own tests:
//!
//! ```text
//!   drop-newest         1  2  3      7 lost
//!   keep-recent         8  9 10      7 lost
//!   silent-while-idle    (nothing)  10 lost
//! ```
//!
//! Note the last row loses *ten*, not seven. The three the others kept were
//! not worth keeping, and this policy says so instead of counting a stale line
//! as a delivered one.
//!
//! # The counter has to change shape too, and that is the subtle part
//!
//! `usb-log` reports loss as a **delta** — `(+50 lines lost)` means fifty
//! since the last surviving line. That number is rendered into one line's
//! text, which is safe only in a queue that never discards what it has already
//! accepted.
//!
//! `keep-recent` discards accepted lines by design. A delta written into a
//! line that is later evicted takes the count with it, so the totals a reader
//! sees would be quietly, unboundedly short. So that build reports a
//! **running total** instead — `(23 lines lost so far)` — which survives
//! eviction because every later line repeats it.
//!
//! A delta is not safe in a queue that can throw things away. That falls out
//! of the policy rather than being a separate feature, and it is the part of
//! this experiment that was not visible before writing it down.
//!
//! # The flag that cannot be asked for
//!
//! `silent-while-idle` needs to know whether a reader is present, and
//! [`usb_log::log`] is an ordinary synchronous function with no access to the
//! USB sender. It cannot ask. It has to be *told*, by the writer task, which
//! is the only thing that ever looks at DTR.
//!
//! That creates a trap worth seeing: if the flag starts `false`, nothing is
//! ever queued, so the writer never wakes, so it never looks at DTR, so the
//! flag never becomes true. A deadlock assembled from two correct halves. It
//! starts `true`, and the cost is exactly one line — the first thing said into
//! a closed port is queued, the writer collects it, finds DTR low, and sets the
//! flag. That one held line is the last thing before the silence, which is a
//! reasonable thing to find waiting.
//!
//! # What this firmware is
//!
//! A ticker. One line a second, numbered, naming its own policy on every line
//! because under `keep-recent` the boot banner is the *first* thing evicted —
//! a build that announced itself only at startup would become unidentifiable
//! by the time anybody connected, which is the original failure wearing a
//! disguise.
//!
//! The heartbeat blink stays, because after this the log is not proof of much:
//! two of the three builds will deliberately show you nothing for a while.

#![no_std]
#![no_main]

use core::sync::atomic::{AtomicU32, Ordering};

use embassy_executor::Spawner;
use embassy_futures::select::{select, Either};
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

const PACKET: usize = 64;

/// One line per second, and the number matters.
///
/// [`usb_log::QUEUE_DEPTH`] is 16, so a closed port fills the queue in exactly
/// sixteen seconds and every second after that is a decision the policy makes.
/// A rate anybody can do arithmetic on in their head is worth more here than a
/// realistic one: the tick number *is* the measurement.
const TICK: Duration = Duration::from_secs(1);

const BLINK_ON: Duration = Duration::from_millis(50);
const BLINK_OFF: Duration = Duration::from_millis(950);

static TICKS: AtomicU32 = AtomicU32::new(0);

#[embassy_executor::task]
async fn usb_task(mut device: UsbDevice<'static, Driver<'static, USB>>) -> ! {
    device.run().await
}

#[embassy_executor::task]
async fn log_task(sender: Sender<'static, usb_reboot::UsbDriver>) -> ! {
    usb_log::run(sender).await
}

/// The 1200-baud watcher, and nothing else.
///
/// This firmware has no commands. The watcher is here for the same reason it
/// is in every firmware from exp105 onwards: without it the next person to
/// change this board needs a hand on the BOOTSEL button, and two of the three
/// builds here are ones you will want to swap between repeatedly.
#[embassy_executor::task]
async fn control_task(
    control: ControlChanged<'static>,
    mut receiver: Receiver<'static, usb_reboot::UsbDriver>,
) -> ! {
    let mut buf = [0u8; PACKET];
    loop {
        match select(control.control_changed(), receiver.read_packet(&mut buf)).await {
            Either::First(()) => {
                let rate = receiver.line_coding().data_rate();
                usb_reboot::reboot_if_requested(rate).await;
            }
            // Nothing here reads commands. Bytes are collected and discarded
            // rather than ignored: an OUT endpoint that nobody drains leaves a
            // packet armed, which is the failure crates/usb-log's writer was
            // built to avoid on the other direction.
            Either::Second(_) => {}
        }
    }
}

/// One numbered line a second, forever.
///
/// Every line carries the policy name. That is not decoration: under
/// `keep-recent` this line is the only surviving evidence of which build is
/// flashed, because the boot banner was evicted long ago.
#[embassy_executor::task]
async fn tick_task() -> ! {
    loop {
        Timer::after(TICK).await;
        let n = TICKS.fetch_add(1, Ordering::Relaxed) + 1;
        log!("tick #{} ({})", n, usb_log::POLICY.name());
    }
}

#[embassy_executor::task]
async fn blink_task(mut led: Output<'static>) -> ! {
    loop {
        led.set_high();
        Timer::after(BLINK_ON).await;
        led.set_low();
        Timer::after(BLINK_OFF).await;
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let p = embassy_rp::init(Default::default());

    // Board-specific: the LED's GPIO. One line, clearly marked.
    let led = Output::new(p.PIN_25, Level::Low);

    let driver = Driver::new(p.USB, Irqs);

    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some("exp134 the log nobody reads");
    config.serial_number = Some("134");
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
    spawner.spawn(tick_task().unwrap());
    spawner.spawn(blink_task(led).unwrap());

    // Said once, and under two of the three policies you will never see it.
    // That is the experiment, stated by the firmware in the one line most
    // likely to be thrown away.
    log!(
        "exp134 up. policy {}, queue {} lines, one tick per second.",
        usb_log::POLICY.name(),
        usb_log::QUEUE_DEPTH
    );
}
