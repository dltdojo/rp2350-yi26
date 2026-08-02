//! exp119 — the read that was cancelled, and what it cost.
//!
//! exp118 ended on an open question. Its `select` loop drops an unfinished
//! `read_packet` every time a control event wins, and it would not claim
//! whether that costs a packet. This experiment answers it by counting.
//!
//! # The answer is in the driver, and it is worth reading first
//!
//! `embassy-rp`'s OUT endpoint read is three steps:
//!
//! ```ignore
//! let val = poll_fn(|cx| {                       // 1. wait
//!     EP_OUT_WAKERS[index].register(cx.waker());
//!     let val = T::dpram().ep_out_buffer_control(index).read();
//!     if val.available(0) { Poll::Pending } else { Poll::Ready(val) }
//! }).await;
//!
//! self.buf.read(&mut buf[..rx_len]);             // 2. copy out of DPRAM
//! w.set_available(0, true);                      // 3. re-arm the endpoint
//! ```
//!
//! **There is exactly one `await`, and it happens before anything is
//! consumed.** Steps 2 and 3 are straight-line code with no suspension point
//! between them, so a dropped future cannot land in the middle of them.
//!
//! And what the wait is waiting on is not a software flag but the hardware's
//! own buffer-control register. Nobody clears it; the packet sits in DPRAM
//! with `available == 0` until some `read()` copies it out. A cancelled read
//! leaves that register exactly as it found it, so the next read sees the same
//! packet.
//!
//! That is a different mechanism from the one exp118 relies on. There, the
//! control event survives cancellation because `embassy-usb` latches it in an
//! `AtomicBool` that is only cleared when observed. Here it survives because
//! the state was never in software to begin with. Same guarantee, two
//! unrelated reasons — which is why neither of them should be assumed from the
//! other.
//!
//! # Why a result of "no packets lost" would otherwise prove nothing
//!
//! A run that loses nothing because no read was ever cancelled is not
//! evidence. So the number that matters most here is not `gaps` — it is
//! `cancels`.
//!
//! In the loop below, a control event can only win the `select` while a
//! `read_packet` is being polled. That is what a cancellation *is*. Counting
//! the wins therefore counts the cancellations exactly, with no extra
//! machinery, and a run reporting `cancels: 0` is a run that tested nothing.
//! `yi26 flood --storm` exists to keep that number large.
//!
//! # Counting without disturbing what is counted
//!
//! Nothing in the hot loop logs. A line per control event during a storm would
//! be thousands of lines a second into a sixteen-line queue, which would drop
//! most of them, stall the loop, and change the very timing under test — the
//! mistake exp110's probe was built to avoid. The loop only increments
//! atomics; a separate task reports them once a second.

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

/// Every packet starts with its sequence number as a little-endian `u32`.
/// Four bytes is the whole protocol; the rest of the packet is filler.
const SEQ_BYTES: usize = 4;

/// Sequence zero means "a new run starts here". Without it the second run of
/// `yi26 flood` would look like one enormous gap, and the counters would have
/// to be cleared by reflashing — which would also clear the thing under test.
const RESET_SEQ: u32 = 0;

const REPORT_EVERY: Duration = Duration::from_secs(1);

/// Packets whose sequence number was exactly the one expected.
static RECEIVED: AtomicU32 = AtomicU32::new(0);
/// Sequence numbers that never arrived. This is the number the experiment is
/// about, and the answer is expected to be zero.
static GAPS: AtomicU32 = AtomicU32::new(0);
/// Packets that arrived with a sequence number already seen. Bulk transfers
/// are ordered and delivered once, so this should be zero too — and if it is
/// not, the assumption that a gap means a loss needs re-examining.
static REPEATS: AtomicU32 = AtomicU32::new(0);
/// Reads cancelled by a control event winning the `select`. **The control
/// variable.** A run where this is zero has tested nothing.
static CANCELS: AtomicU32 = AtomicU32::new(0);
/// Packets too short to carry a sequence number, including the zero-length one
/// exp118 found at startup. Counted rather than ignored, because a silent
/// discard is how a miscount hides.
static RUNTS: AtomicU32 = AtomicU32::new(0);
/// The sequence number expected next.
static EXPECT: AtomicU32 = AtomicU32::new(1);
/// What [`report_task`] saw last time it looked.
///
/// A static, and not a local in that task, because a reset has to be able to
/// clear it. It was a local for exactly one run: the second `yi26 flood`
/// reset the six counters above, `RECEIVED` climbed back to the same total as
/// the first run, and the reporter — comparing against its own untouched
/// stack — concluded nothing had changed and said nothing at all. Six
/// counters cleared and the seventh missed, because the seventh was somewhere
/// the reset could not reach.
static REPORTED: AtomicU32 = AtomicU32::new(0);

#[embassy_executor::task]
async fn usb_task(mut device: UsbDevice<'static, Driver<'static, USB>>) -> ! {
    device.run().await
}

#[embassy_executor::task]
async fn log_task(sender: Sender<'static, usb_reboot::UsbDriver>) -> ! {
    usb_log::run(sender).await
}

/// exp118's loop, with counters instead of a hex dump.
///
/// The shape is identical on purpose: one task owning the `Receiver`, waiting
/// on the control line and the OUT endpoint at once, because
/// `ControlChanged` cannot read the line coding and `read_packet` needs
/// `&mut Receiver`. exp118 explains why that is forced rather than chosen.
#[embassy_executor::task]
async fn counter_task(
    control: ControlChanged<'static>,
    mut receiver: Receiver<'static, usb_reboot::UsbDriver>,
) -> ! {
    let mut buf = [0u8; PACKET];

    loop {
        match select(control.control_changed(), receiver.read_packet(&mut buf)).await {
            // A control event won, which means a `read_packet` was in flight
            // and has just been dropped unfinished. That is the event this
            // experiment exists to create, so it is counted and nothing else
            // happens here — no logging, at any rate, for the reason in the
            // module docs.
            Either::First(()) => {
                CANCELS.fetch_add(1, Ordering::Relaxed);
                usb_reboot::reboot_if_requested(receiver.line_coding().data_rate()).await;
            }

            Either::Second(Ok(n)) if n >= SEQ_BYTES => {
                let seq = u32::from_le_bytes([buf[0], buf[1], buf[2], buf[3]]);

                if seq == RESET_SEQ {
                    RECEIVED.store(0, Ordering::Relaxed);
                    GAPS.store(0, Ordering::Relaxed);
                    REPEATS.store(0, Ordering::Relaxed);
                    CANCELS.store(0, Ordering::Relaxed);
                    RUNTS.store(0, Ordering::Relaxed);
                    EXPECT.store(1, Ordering::Relaxed);
                    REPORTED.store(0, Ordering::Relaxed);
                    log!("run starts: counters cleared by sequence 0");
                    continue;
                }

                let expect = EXPECT.load(Ordering::Relaxed);
                if seq > expect {
                    // Bulk transfers arrive in order, so anything skipped is
                    // gone rather than late.
                    GAPS.fetch_add(seq - expect, Ordering::Relaxed);
                } else if seq < expect {
                    REPEATS.fetch_add(1, Ordering::Relaxed);
                }
                RECEIVED.fetch_add(1, Ordering::Relaxed);
                EXPECT.store(seq.wrapping_add(1), Ordering::Relaxed);
            }

            // Short packets cannot carry a sequence number. exp118 established
            // that this board produces one zero-length read at startup.
            Either::Second(Ok(_)) => {
                RUNTS.fetch_add(1, Ordering::Relaxed);
            }

            Either::Second(Err(_)) => {
                receiver.wait_connection().await;
            }
        }
    }
}

/// The only thing that prints. Once a second, whatever is happening.
///
/// It reports on two occasions: while the count is moving, and once it has
/// stopped. The second is not padding. A run's result is only final when
/// nothing more is arriving, and an edge-triggered reporter goes quiet at
/// precisely the moment somebody wants the total — which is what the first
/// version of this did, leaving `yi26 flood` printing a reset line and then
/// nothing.
#[embassy_executor::task]
async fn report_task() -> ! {
    let mut quiet_ticks: u32 = 0;

    loop {
        Timer::after(REPORT_EVERY).await;

        let received = RECEIVED.load(Ordering::Relaxed);
        let reported = REPORTED.swap(received, Ordering::Relaxed);

        if received == reported {
            quiet_ticks += 1;
            // The settling report, then a restatement every RESTATE_TICKS.
            // Restated rather than said once, because somebody may attach a
            // terminal at any moment and this repository has learned three
            // times that a fact printed once is a fact nobody sees.
            const RESTATE_TICKS: u32 = 10;
            if quiet_ticks == 1 || quiet_ticks % RESTATE_TICKS == 0 {
                if received == 0 {
                    log!("idle: nothing received — try  yi26 flood --storm");
                } else {
                    log!("settled: {} packets, nothing further arriving", received);
                    verdict();
                }
            }
            continue;
        }

        quiet_ticks = 0;
        log!(
            "rx {} (+{}/s)  gaps {}  repeats {}  cancels {}  runts {}",
            received,
            received - reported,
            GAPS.load(Ordering::Relaxed),
            REPEATS.load(Ordering::Relaxed),
            CANCELS.load(Ordering::Relaxed),
            RUNTS.load(Ordering::Relaxed)
        );
        verdict();
    }
}

/// States what the numbers mean, rather than leaving it to be worked out.
///
/// `gaps 0` on its own is not a result. Beside `cancels 0` it says only that
/// nothing was tested, and the difference between those two readings is the
/// whole experiment.
fn verdict() {
    let cancels = CANCELS.load(Ordering::Relaxed);
    let gaps = GAPS.load(Ordering::Relaxed);

    if cancels == 0 {
        log!("   -> 0 cancelled reads: this run has tested nothing");
    } else if gaps == 0 {
        log!("   -> {} reads cancelled, nothing lost", cancels);
    } else {
        log!("   -> {} reads cancelled, {} PACKETS LOST", cancels, gaps);
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let p = embassy_rp::init(Default::default());
    let mut led = Output::new(p.PIN_25, Level::Low);

    let driver = Driver::new(p.USB, Irqs);

    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some("exp119 cancelled reads");
    config.serial_number = Some("119");
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
    spawner.spawn(counter_task(control, receiver).unwrap());
    spawner.spawn(report_task().unwrap());

    log!("exp119 up. Counting packets, and counting cancelled reads.");

    loop {
        led.set_high();
        Timer::after(Duration::from_millis(50)).await;
        led.set_low();
        Timer::after(Duration::from_millis(950)).await;
    }
}
