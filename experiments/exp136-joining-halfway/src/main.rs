//! exp136 — a boundary you can join halfway.
//!
//! [exp128](../../exp128-reassemble-by-hand/) took the boundary from USB: a
//! message ends at the first packet shorter than 64 bytes.
//! [exp135](../../exp135-a-packet-with-no-bytes/) paid what that costs — one
//! unterminated message silently swallows the next, and only a program holding
//! the interface can send the packet that ends it.
//!
//! So the boundary moves up, out of the transport and into the bytes. This
//! firmware runs a **deframer**: it feeds every byte it receives to
//! `crates/framing` and prints the messages that come out, along with how many
//! bytes it threw away not knowing where it was.
//!
//! # The question is not which framing is better
//!
//! Both schemes work perfectly on a stream read from its first byte. The
//! interesting case is the one that actually happens: **the reader arrives
//! late.** A log page opened after the board has been talking for a minute, a
//! `yi26` that attaches mid-message, a cable pushed back in. A decoder that
//! only works from byte zero works exactly once.
//!
//! - **Length-prefix** (`0xA5`, length, payload) hunts for its magic byte, and
//!   a payload can contain one. It resynchronises **by luck**.
//! - **COBS** reserves a byte the payload can never contain. It resynchronises
//!   **by construction**.
//!
//! `crates/framing` sweeps that at every offset of a stream, with no board
//! involved, and finds the trade is not the one the comparison was set up to
//! expect: length-prefix loses *fewer* messages, and delivers three that were
//! never sent. This firmware is where you watch one of those arrive.
//!
//! # Two builds, one source
//!
//! ```sh
//! cargo build --release                 # length-prefix
//! cargo build --release --features cobs # COBS
//! ```
//!
//! The choice is a type alias in the crate, so nothing below names a scheme.
//! Both builds print which one they are at boot, because a capture that does
//! not say what produced it is not evidence.
//!
//! # The demonstration this firmware exists for
//!
//! Send these two byte strings to the length-prefix build, in order:
//!
//! ```text
//! a5 08 00 a5 05 00 61 62 63 64 65     the whole frame  → msg: 8 bytes
//!          a5 05 00 61 62 63 64 65     the same bytes, joined three in
//!                                      → msg: 5 bytes "abcde"
//! ```
//!
//! The second line is not a message. It is the *middle of one*, and the
//! decoder cannot tell — it reads a magic byte, a length of five, and hands up
//! five bytes nobody sent. Do the same to the COBS build and the tail is
//! discarded in silence, because the only thing that can end a message there
//! is a byte the payload is incapable of containing.
//!
//! # What this firmware does not have
//!
//! A checksum. Neither scheme here has one, and a frame layer without one
//! cannot tell a corrupted payload from a real one — which in most protocols
//! matters more than resynchronisation. The comparison is deliberately narrow;
//! see the crate's own docs for what it declines to claim.

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
use framing::Deframer as _;
use panic_halt as _;
use rp2350_linker as _;
use static_cell::StaticCell;
use usb_log::log;

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
});

/// One CDC packet.
///
/// It appears once, to size the endpoint, and nowhere else — which is the
/// difference between this firmware and exp128. When the boundary is in the
/// bytes, the packet size stops being part of the protocol.
const PACKET: usize = 64;

/// How often the idle line repeats.
const IDLE_REPORT: Duration = Duration::from_secs(5);

static MESSAGES: AtomicU32 = AtomicU32::new(0);
static PACKETS: AtomicU32 = AtomicU32::new(0);
static DISCARDED: AtomicU32 = AtomicU32::new(0);

/// Renders bytes as text, one dot per byte that is not printable ASCII.
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

/// Read packets, feed bytes, print messages.
///
/// The loop takes packets because that is what the class hands out, and then
/// forgets about them immediately: every byte goes into the deframer whatever
/// packet it came in, and a message can end in the middle of one. That is the
/// whole point of moving the boundary — exp128's loop had to care where
/// packets ended, and this one is not allowed to.
#[embassy_executor::task]
async fn console_task(
    control: ControlChanged<'static>,
    mut receiver: Receiver<'static, usb_reboot::UsbDriver>,
) -> ! {
    let mut packet = [0u8; PACKET];

    // The decoder starts as one that has just joined a stream in progress —
    // which is exactly what a freshly enumerated device is. The host has been
    // running for hours; the board has been alive for milliseconds.
    let mut deframer = <framing::Selected as framing::Start>::joined();
    let mut discarded_seen = 0usize;

    loop {
        match select(control.control_changed(), receiver.read_packet(&mut packet)).await {
            Either::First(()) => {
                let rate = receiver.line_coding().data_rate();
                log!(
                    "control: {} baud, DTR {}",
                    rate,
                    if receiver.dtr() { "on" } else { "off" }
                );
                usb_reboot::reboot_if_requested(rate).await;
            }

            Either::Second(Ok(n)) => {
                if n == 0 {
                    // exp118 settled this one: the endpoint completing empty as
                    // it is enabled. With the boundary in the bytes it is not
                    // even interesting — a zero-length packet carries no bytes,
                    // and bytes are all this firmware reads.
                    continue;
                }
                PACKETS.fetch_add(1, Ordering::Relaxed);

                for &byte in &packet[..n] {
                    if let Some(len) = deframer.feed(byte) {
                        let seq = MESSAGES.fetch_add(1, Ordering::Relaxed) + 1;
                        log!("msg #{}: {} bytes: {}", seq, len, Printable(deframer.payload()));

                        // Bytes read while the decoder did not know where it
                        // was. Reported per message rather than as a total,
                        // because what a reader wants to know is what *this*
                        // message cost to find.
                        let total = deframer.discarded();
                        if total > discarded_seen {
                            log!("  found after discarding {} bytes", total - discarded_seen);
                            discarded_seen = total;
                            DISCARDED.store(total as u32, Ordering::Relaxed);
                        }
                    }
                }

                // Said every packet, because silence after a send is the thing
                // a reader misreads. exp128 printed `N held` for the same
                // reason and it was the most useful line in that experiment.
                let total = deframer.discarded();
                if total > discarded_seen {
                    log!(
                        "  {} bytes discarded, no message — still looking for a boundary",
                        total - discarded_seen
                    );
                    discarded_seen = total;
                    DISCARDED.store(total as u32, Ordering::Relaxed);
                }
            }

            Either::Second(Err(_)) => {
                receiver.wait_connection().await;
                log!("interface enabled again — listening");
            }
        }
    }
}

#[embassy_executor::task]
async fn idle_task() -> ! {
    loop {
        Timer::after(IDLE_REPORT).await;

        // The scheme is named here, in the line that repeats, and not only in
        // the boot banner. exp134 is the reason: a queue sixteen lines deep
        // drops the oldest first, so the one line that said which build this
        // is has aged out by the time anybody connects. A capture that cannot
        // say what produced it is not evidence, and this is the cheapest
        // possible way for it to keep saying so.
        let msgs = MESSAGES.load(Ordering::Relaxed);
        if msgs == 0 {
            log!(
                "idle: {} — nothing yet; it wants a framed message, not a line",
                framing::SCHEME
            );
        } else {
            log!(
                "idle: {} — {} message{} from {} packets, {} bytes discarded",
                framing::SCHEME,
                msgs,
                if msgs == 1 { "" } else { "s" },
                PACKETS.load(Ordering::Relaxed),
                DISCARDED.load(Ordering::Relaxed)
            );
        }
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let p = embassy_rp::init(Default::default());

    // Board-specific: the LED's GPIO. A plain heartbeat.
    let mut led = Output::new(p.PIN_25, Level::Low);

    let driver = Driver::new(p.USB, Irqs);

    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some("exp136 joining halfway");
    config.serial_number = Some("136");
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

    // Unchanged since exp104. Moving the message boundary into the payload
    // changes nothing a host can see: same class, same endpoints, same 64-byte
    // packets. The descriptors have no opinion about what the bytes mean.
    let class = CdcAcmClass::new(&mut builder, ACM_STATE.init(State::new()), PACKET as u16);
    let usb = builder.build();
    spawner.spawn(usb_task(usb).unwrap());

    let (sender, receiver, control) = class.split_with_control();
    spawner.spawn(log_task(sender).unwrap());
    spawner.spawn(console_task(control, receiver).unwrap());
    spawner.spawn(idle_task().unwrap());

    log!(
        "exp136 up. deframer: {}, max payload {} bytes.",
        framing::SCHEME,
        framing::MAX_PAYLOAD
    );

    loop {
        led.set_high();
        Timer::after(Duration::from_millis(50)).await;
        led.set_low();
        Timer::after(Duration::from_millis(950)).await;
    }
}
