//! exp128 — reassemble by hand.
//!
//! exp118 printed what arrived and refused to pretend it was a message: a
//! hundred bytes written once came back as `64` and then `36`. exp127 dodged
//! the problem entirely by making its commands one byte long, and said so.
//!
//! This one pays the bill. The host writes a message of any length and the
//! firmware puts it back together, so `msg #1: 100 bytes` is a line that can
//! finally be printed honestly.
//!
//! # The boundary is on the wire, and the class will not hand it to you
//!
//! It is worth being clear that USB is not missing the information. A bulk
//! transfer ends at the **first packet shorter than `wMaxPacketSize`** — the
//! host controller puts it there, the device sees it, and no guessing is
//! involved. `embassy-usb-driver` even has a method for exactly this, with a
//! default implementation that is four lines long:
//!
//! ```ignore
//! // embassy-usb-driver-0.2.2/src/lib.rs:273
//! async fn read_transfer(&mut self, buf: &mut [u8]) -> Result<usize, EndpointError> {
//!     let mut n = 0;
//!     loop {
//!         let i = self.read(&mut buf[n..]).await?;
//!         n += i;
//!         if i < self.info().max_packet_size as usize {
//!             return Ok(n);
//!         }
//!     }
//! }
//! ```
//!
//! **`CdcAcmClass`'s `Receiver` does not expose it.** Its entire read surface
//! is `read_packet`, which forwards one packet from the OUT endpoint and
//! nothing else. The method exists on the `EndpointOut` trait; a firmware
//! holding a raw endpoint — exp122's vendor interface, for one — can call it.
//! A firmware holding a CDC `Receiver` cannot.
//!
//! That is not an oversight, it is CDC-ACM being what it claims to be. The
//! class presents a serial port, RS-232 has no message boundaries, so the
//! abstraction discards the one the wire underneath it was carrying. The loop
//! in `console_task` below is that discarded boundary, put back by hand.
//!
//! `Receiver::into_buffered` is not the way out either, despite the name. Its
//! own documentation says it exists so a caller can read *fewer* bytes than a
//! packet, for `embedded_io_async::Read` — it turns packets into a byte stream
//! with no boundaries at all, which is further from a message rather than
//! closer.
//!
//! # What this firmware will not do, and it is not hypothetical
//!
//! A message whose length is an exact multiple of 64 has no short packet to
//! end it. This firmware will sit and wait, and the next message the host
//! sends will be appended to the one already buffered — which is not a hang
//! but a silent corruption, and worse for it.
//!
//! That is measured, not feared. Against exp118, on the machine this was
//! written on:
//!
//! ```text
//! yi26 send <64 bytes>    →  in #1: 64 bytes          (and nothing else)
//! yi26 send <128 bytes>   →  in #2: 64 bytes
//!                            in #3: 64 bytes          (and nothing else)
//! ```
//!
//! No zero-length packet followed either one. The host had no reason to send
//! one: it wrote exactly what it was asked to write.
//!
//! So this firmware says out loud when it has taken a full packet and cannot
//! know whether the message is over, and it caps the buffer rather than
//! growing forever. Making a 64-byte message arrive is the fix, it has a name
//! — a zero-length packet — and exp135 sends one.
//!
//! # One case that looks like a bug and is not
//!
//! `read_packet` returning 0 means two entirely different things depending on
//! when it happens. At startup it is the endpoint completing empty as it is
//! enabled, which exp118 established and which nobody sent. Mid-message it is
//! a **zero-length packet**, which is shorter than 64 and therefore ends the
//! message — the terminator this experiment says is missing. Both are handled
//! below, differently, and the log says which one it saw.

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

/// One CDC packet, and the number this whole experiment turns on: a packet
/// this size might be the end of a message and might not, and a shorter one
/// always is.
const PACKET: usize = 64;

/// How long a message this firmware will hold before giving up on it.
///
/// Four packets. Small on purpose: a reader who wants to see the cap fire
/// should not have to type kilobytes, and a firmware that buffers without a
/// limit is a firmware waiting for someone to fill its RAM.
const MESSAGE: usize = PACKET * 4;

/// How many packet sizes are remembered per message, for the log line.
///
/// The sizes are the evidence — `100 bytes, 2 packets: 64 36` is the whole
/// experiment in one line — but a full message is four of them and a log line
/// is 96 characters. Six is more than a capped message can produce.
const SIZES: usize = 6;

/// How often the idle line repeats.
const IDLE_REPORT: Duration = Duration::from_secs(5);

static MESSAGES: AtomicU32 = AtomicU32::new(0);
static PACKETS: AtomicU32 = AtomicU32::new(0);
static PENDING: AtomicU32 = AtomicU32::new(0);

/// Renders the packet sizes a message arrived in.
struct Sizes<'a>(&'a [u16], usize);

impl core::fmt::Display for Sizes<'_> {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        for (i, n) in self.0.iter().enumerate() {
            if i > 0 {
                f.write_char(' ')?;
            }
            write!(f, "{}", n)?;
        }
        // A message that took more packets than there is room to name says so
        // rather than silently reporting the first six as if they were all.
        if self.1 > self.0.len() {
            f.write_str(" ...")?;
        }
        Ok(())
    }
}

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

/// Everything exp118's console task did, plus the loop that turns packets
/// back into messages.
///
/// Still one task, for exp118's reason: there is exactly one `Receiver`, and
/// the 1200-baud watcher needs it to read the line coding.
#[embassy_executor::task]
async fn console_task(
    control: ControlChanged<'static>,
    mut receiver: Receiver<'static, usb_reboot::UsbDriver>,
) -> ! {
    let mut packet = [0u8; PACKET];

    // The message being assembled. `held` is how much of it has arrived;
    // `sizes`/`count` are what it arrived in.
    let mut message = [0u8; MESSAGE];
    let mut held = 0usize;
    let mut sizes = [0u16; SIZES];
    let mut count = 0usize;

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
                // A zero-length read with nothing buffered is the endpoint
                // completing empty as it is enabled — exp118 settled that, and
                // nobody sent it. With a message in progress it is a real
                // zero-length packet, which is shorter than 64 and therefore
                // the terminator this experiment says nothing provides.
                if n == 0 && held == 0 {
                    log!("zero-length packet — nobody sent it");
                    continue;
                }

                PACKETS.fetch_add(1, Ordering::Relaxed);

                // Truncate rather than overrun. A message longer than the cap
                // is reported below; it is never written past the end.
                let room = MESSAGE - held;
                let take = if n < room { n } else { room };
                message[held..held + take].copy_from_slice(&packet[..take]);
                held += take;
                if count < SIZES {
                    sizes[count] = n as u16;
                }
                count += 1;
                PENDING.store(held as u32, Ordering::Relaxed);

                let short = n < PACKET;
                let full = held >= MESSAGE;

                if short {
                    let seq = MESSAGES.fetch_add(1, Ordering::Relaxed) + 1;
                    if n == 0 {
                        log!("msg #{}: {} bytes, ended by a zero-length packet", seq, held);
                    } else {
                        log!(
                            "msg #{}: {} bytes, {} packet{}: {}",
                            seq,
                            held,
                            count,
                            if count == 1 { "" } else { "s" },
                            Sizes(&sizes[..count.min(SIZES)], count)
                        );
                    }
                    // A preview, not a dump. The sizes above are the evidence
                    // this experiment is about; the payload is only here so a
                    // reader can see it is the bytes they typed.
                    let head = &message[..held.min(24)];
                    log!("  {}{}", Printable(head), if held > 24 { "..." } else { "" });
                    held = 0;
                    count = 0;
                    PENDING.store(0, Ordering::Relaxed);
                } else if full {
                    // The cap, and it is a loss. Said in those words because
                    // a firmware that quietly drops a message is the failure
                    // this repository keeps finding.
                    log!("buffer full at {} bytes — no short packet ever came", held);
                    log!("  discarded; a message this long needs framing, not a bigger buffer");
                    held = 0;
                    count = 0;
                    PENDING.store(0, Ordering::Relaxed);
                } else {
                    // The honest half of the trap: a full packet might be the
                    // end of a message and might not, and nothing here can
                    // tell. Printed every time, so the wait is never silent.
                    log!("  +{} full packet, {} held — the message may not be over", n, held);
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

        let pending = PENDING.load(Ordering::Relaxed);
        if pending > 0 {
            log!("idle: {} bytes held, waiting for a packet under 64", pending);
            log!("  send anything short and it will complete — wrongly");
            continue;
        }

        let msgs = MESSAGES.load(Ordering::Relaxed);
        if msgs == 0 {
            log!("idle: nothing yet — try  yi26 send hello");
        } else {
            log!(
                "idle: {} message{} from {} packets",
                msgs,
                if msgs == 1 { "" } else { "s" },
                PACKETS.load(Ordering::Relaxed)
            );
        }
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let p = embassy_rp::init(Default::default());

    // Board-specific: the LED's GPIO. A plain heartbeat here — exp127's
    // question of who owns it is a different experiment.
    let mut led = Output::new(p.PIN_25, Level::Low);

    let driver = Driver::new(p.USB, Irqs);

    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some("exp128 reassemble by hand");
    config.serial_number = Some("128");
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

    // Unchanged since exp104, again. Reassembly is a decision the firmware
    // makes about bytes it already had; nothing about it is visible to the
    // host, and `endpoint 0x01 OUT bulk 64 bytes` is the same endpoint.
    let class = CdcAcmClass::new(&mut builder, ACM_STATE.init(State::new()), PACKET as u16);
    let usb = builder.build();
    spawner.spawn(usb_task(usb).unwrap());

    let (sender, receiver, control) = class.split_with_control();
    spawner.spawn(log_task(sender).unwrap());
    spawner.spawn(console_task(control, receiver).unwrap());
    spawner.spawn(idle_task().unwrap());

    log!("exp128 up. A message ends at the first packet under 64 bytes.");

    loop {
        led.set_high();
        Timer::after(Duration::from_millis(50)).await;
        led.set_low();
        Timer::after(Duration::from_millis(950)).await;
    }
}
