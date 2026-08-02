//! exp118 — one receiver, two jobs.
//!
//! Every experiment so far has talked *at* the host. This one listens. The
//! host sends bytes, the firmware prints what arrived, and the round trip
//! finally closes.
//!
//! Nothing about the device changes to make that possible. CDC-ACM has always
//! had an OUT endpoint — exp115's descriptor tree lists it, `endpoint 0x01
//! OUT bulk 64 bytes`, and every firmware in this repository has had one since
//! exp104. The endpoint was there; nobody was reading it.
//!
//! # The obstacle is ownership, and it is worth meeting
//!
//! The naive plan is exp107's: add a task that reads. It does not work here,
//! and the reason is the interesting part.
//!
//! `CdcAcmClass::split_with_control()` hands out three pieces:
//!
//! ```text
//!   Sender          write_packet, line_coding, dtr    → usb_log::run
//!   Receiver        read_packet,  line_coding, dtr    → usb_reboot::watch
//!   ControlChanged  control_changed,           dtr    → usb_reboot::watch
//! ```
//!
//! Look at what `ControlChanged` does *not* have: `line_coding`. The 1200-baud
//! reboot from exp105 has to know the host's baud rate, so
//! [`usb_reboot::watch`] takes the `Receiver` — not to read from it, only to
//! ask it a question. That was free while nothing else wanted the OUT
//! endpoint. It is not free now: `read_packet` needs `&mut Receiver`, and
//! there is exactly one `Receiver`.
//!
//! So the choice is not stylistic:
//!
//! - reader task owns it → the reboot watcher cannot see the baud rate, the
//!   1200-baud touch stops working, and the board can only be reflashed by a
//!   human holding BOOTSEL;
//! - watcher owns it → nothing can read what the host sends.
//!
//! One task has to do both, which means waiting on two things at once. That
//! is [`select`], and it arrives here as a consequence rather than as a
//! feature to be shown off.
//!
//! # What `select` does to the loser
//!
//! `select` polls two futures and returns as soon as either finishes. The
//! other one is **dropped, unfinished**. Whether that costs anything is a fair
//! question to ask about any cancellation, and here it has two different
//! answers.
//!
//! For the control-change side the answer is no, and it is worth checking
//! rather than hoping, because the cost of being wrong is a board that cannot
//! be reflashed. `embassy-usb` stores the event as a latching flag:
//!
//! ```ignore
//! if self.changed.load(Ordering::Relaxed) {
//!     self.changed.store(false, Ordering::Relaxed);   // cleared only when observed
//!     Poll::Ready(())
//! }
//! ```
//!
//! A dropped `control_changed()` future never observes the flag, so the flag
//! stays set and the very next poll returns immediately. The 1200-baud request
//! cannot be lost by cancellation.
//!
//! For the read side the answer is "not established here". A `read_packet`
//! dropped mid-flight might or might not cost a packet, and this experiment
//! deliberately does not claim either way — it prints a sequence number on
//! every packet so that a gap would be visible. Measuring that properly is
//! exp119.
//!
//! # A message is not a thing USB has
//!
//! The counter below is called `PACKETS` and not `MESSAGES`, because the first
//! run of this firmware settled the question. Sending a hundred bytes produces
//! **two** log entries, not one:
//!
//! ```text
//! in #4: 64 bytes
//! in #5: 36 bytes
//! ```
//!
//! One `write` on the host, two `read_packet`s on the device. The host's USB
//! stack cuts the transfer into packets of the endpoint's size — the 64 that
//! `CdcAcmClass::new` was given — and the firmware is handed the pieces. There
//! is no length prefix and no delimiter, because a bulk endpoint carries no
//! such thing. Any firmware that wants messages has to define what one is and
//! reassemble them itself. This one does not: it prints what actually arrived,
//! which is the honest thing to show first.

#![no_std]
#![no_main]

use core::fmt::Write as _;
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

/// One CDC packet. The endpoint was created with this size in [`main`], and
/// `read_packet` requires a buffer at least that large.
const PACKET: usize = 64;

/// Bytes per line of the dump.
///
/// `usb_log::LINE_CAPACITY` is 96 and the timestamp prefix eats thirteen of
/// them, so a 64-byte packet cannot be one line: its hex alone is 191
/// characters. Sixteen per row costs four lines for a full packet and stays
/// inside the budget with room to spare — and a dump is easier to read than a
/// long unbroken string anyway.
const ROW: usize = 16;

/// How often the idle line repeats.
///
/// It repeats because this repository has learned three times that a fact
/// printed once is a fact nobody sees. Somebody attaching a terminal two
/// minutes after boot must still be told what this firmware wants from them.
const IDLE_REPORT: Duration = Duration::from_secs(5);

/// Counters, shared with the reporter task.
///
/// Two tasks, two plain atomics, no channel. The reporter only reads and the
/// console only writes, so there is nothing here that a lock would protect.
static PACKETS: AtomicU32 = AtomicU32::new(0);
static BYTES: AtomicU32 = AtomicU32::new(0);

/// Renders bytes as a fixed-width hex column, padded so the text beside it
/// lines up whether the row is full or not.
struct Hex<'a>(&'a [u8]);

impl core::fmt::Display for Hex<'_> {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        for i in 0..ROW {
            match self.0.get(i) {
                Some(b) => write!(f, "{:02x} ", b)?,
                None => f.write_str("   ")?,
            }
        }
        Ok(())
    }
}

/// Renders bytes as text, with one dot per byte that is not printable ASCII.
///
/// A dot per byte, not a dot per run: the column has to stay aligned with the
/// hex beside it, and "how many bytes were unprintable" is part of what the
/// reader is trying to see.
struct Printable<'a>(&'a [u8]);

impl core::fmt::Display for Printable<'_> {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        for &b in self.0 {
            f.write_char(if (0x20..0x7f).contains(&b) { b as char } else { '.' })?;
        }
        Ok(())
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

/// The task this experiment exists for: it owns the `Receiver`, so it does
/// both jobs the `Receiver` makes possible.
#[embassy_executor::task]
async fn console_task(
    control: ControlChanged<'static>,
    mut receiver: Receiver<'static, usb_reboot::UsbDriver>,
) -> ! {
    let mut buf = [0u8; PACKET];

    loop {
        match select(control.control_changed(), receiver.read_packet(&mut buf)).await {
            // The host changed DTR, RTS or the line coding. Which of those it
            // was, this API does not say — so read the state and report it,
            // because "something changed" is not a debugging aid.
            Either::First(()) => {
                let rate = receiver.line_coding().data_rate();
                log!(
                    "control: {} baud, DTR {}",
                    rate,
                    if receiver.dtr() { "on" } else { "off" }
                );

                // One copy of the delicate part, in the crate that has been
                // hardware-verified since exp105. If this is the 1200-baud
                // request, the call below does not return.
                usb_reboot::reboot_if_requested(rate).await;
            }

            // A zero-length read is not a message and must not be counted as
            // one. This board produces exactly one at about 37 ms, before the
            // host has asserted DTR — so before anything could have opened the
            // port, let alone typed into it. It is the endpoint completing
            // empty as it is enabled, not somebody sending nothing.
            //
            // Counting it cost nothing visible and broke something invisible:
            // every sequence number below would be one too high, and exp119's
            // whole question is whether a gap in those numbers means a lost
            // packet. A counter that starts by miscounting cannot answer it.
            Either::Second(Ok(0)) => {
                log!("zero-length packet — not counted, nobody sent it");
            }

            Either::Second(Ok(n)) => {
                let data = &buf[..n];
                let seq = PACKETS.fetch_add(1, Ordering::Relaxed) + 1;
                BYTES.fetch_add(n as u32, Ordering::Relaxed);

                // The sequence number is not decoration. exp119 asks whether a
                // cancelled read costs a packet, and a gap in this count is
                // what that question looks like from the outside.
                log!("in #{}: {} bytes", seq, n);
                for (i, row) in data.chunks(ROW).enumerate() {
                    log!("  {:04x}  {} {}", i * ROW, Hex(row), Printable(row));
                }
            }

            // The endpoint is not enabled: the host has not configured the
            // device yet, or has just gone away. Retrying immediately would
            // spin at full speed against a socket that is not there, so wait
            // for the interface to come back.
            //
            // Nothing is watching the control line during this wait, and
            // nothing needs to be: the latching flag described in the module
            // docs holds the event until somebody polls for it.
            Either::Second(Err(_)) => {
                receiver.wait_connection().await;
                log!("interface enabled again — listening");
            }
        }
    }
}

/// Says what this firmware wants, on a loop, forever.
#[embassy_executor::task]
async fn idle_task() -> ! {
    loop {
        Timer::after(IDLE_REPORT).await;

        let packets = PACKETS.load(Ordering::Relaxed);
        if packets == 0 {
            log!("idle: nothing received yet — try  yi26 send hello");
        } else {
            log!(
                "idle: {} packet{}, {} bytes received so far",
                packets,
                if packets == 1 { "" } else { "s" },
                BYTES.load(Ordering::Relaxed)
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
    config.product = Some("exp118 one receiver two jobs");
    config.serial_number = Some("118");
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

    // Identical to every other experiment here, deliberately. The descriptors
    // this produces are byte-for-byte what exp115 already printed: no new
    // interface, no new endpoint, no new class. The only thing that changed is
    // that somebody reads the endpoint that was always there.
    let class = CdcAcmClass::new(&mut builder, ACM_STATE.init(State::new()), PACKET as u16);
    let usb = builder.build();
    spawner.spawn(usb_task(usb).unwrap());

    let (sender, receiver, control) = class.split_with_control();
    spawner.spawn(log_task(sender).unwrap());

    // Where every other experiment spawns `usb_reboot::watch(control,
    // receiver)`, this one spawns a task that has to do that job and one more.
    spawner.spawn(console_task(control, receiver).unwrap());
    spawner.spawn(idle_task().unwrap());

    log!("exp118 up. The OUT endpoint has a reader for the first time.");

    loop {
        led.set_high();
        Timer::after(Duration::from_millis(50)).await;
        led.set_low();
        Timer::after(Duration::from_millis(950)).await;
    }
}
