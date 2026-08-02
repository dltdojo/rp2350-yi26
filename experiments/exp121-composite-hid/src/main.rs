//! exp121 — one cable, two functions.
//!
//! The board has been a composite device since exp104 and has never had a
//! second function to compose. Every firmware here sets the same three bytes
//! in its device descriptor:
//!
//! ```ignore
//! config.device_class    = 0xef;   // Miscellaneous
//! config.device_sub_class = 0x02;  // Common class
//! config.device_protocol  = 0x01;  // Interface Association Descriptor
//! ```
//!
//! That triple is a promise: *this device has several functions, and the
//! interfaces are grouped into them*. exp115's page annotates it. Until now it
//! has been a promise about one function.
//!
//! This experiment keeps it. A HID keyboard is declared alongside the CDC
//! pair, so the board is at once the thing being tested and the thing
//! reporting on the test, **on one cable**. That is the shape a phone needs:
//! one port, and the device under test is already in it.
//!
//! # Built in two steps, on purpose
//!
//! A wrong descriptor does not misbehave. It fails to enumerate — the board
//! draws power, does nothing, and shows up in no listing, so the 1200-baud
//! reflash cannot reach it and the only way back is a hand on the BOOTSEL
//! button. That happened once already in this repository, and it cost its
//! owner a trip to the bench.
//!
//! So the descriptor change lands before the behaviour does. The first build
//! declares the keyboard and never presses anything; only once that
//! enumerates, logs, and still reboots on command does the second build learn
//! to send a report. If the board dies, which of the two did it is not a
//! question anyone has to work out.
//!
//! # It presses Scroll Lock, and nothing else, and only when asked
//!
//! A device that types is a hazard. Whatever window has focus receives it,
//! and on a machine where the same person is running a terminal that is a way
//! to lose work.
//!
//! Scroll Lock is the exception worth knowing: the host tracks its state,
//! shows it in `xset q` and in `/sys/class/leds/*::scrolllock`, and almost
//! nothing in modern software acts on it. A keypress that is recorded and
//! changes nothing — which makes it both safe and *observable from a shell*,
//! with nobody watching a screen.
//!
//! Nothing is pressed unless the host asks over the CDC console, which is
//! exp118's OUT endpoint doing a second job.

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
use embassy_usb::class::hid::{
    Config as HidConfig, HidBootProtocol, HidSubclass, HidWriter, State as HidState,
};
use embassy_usb::{Builder, Config as UsbConfig, UsbDevice};
use panic_halt as _;
use rp2350_linker as _;
use static_cell::StaticCell;
use usb_log::log;
use usbd_hid::descriptor::{KeyboardReport, SerializedDescriptor};

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
});

const PACKET: usize = 64;
const ROW: usize = 16;
const IDLE_REPORT: Duration = Duration::from_secs(5);

/// How often the host is asked to collect a keyboard report.
///
/// Slow on purpose. A real keyboard wants single-digit milliseconds so that
/// typing feels instant; this one presses a key when told to and is idle the
/// rest of the time, and every poll the host makes is bus bandwidth spent on
/// nothing. 64 ms is imperceptible for the one use this device has.
const HID_POLL_MS: u8 = 64;

/// Bytes per HID report: modifier, reserved, LED state, and six key slots.
const HID_REPORT_BYTES: u16 = 8;

/// HID usage ID for Scroll Lock, from the keyboard usage page.
///
/// Chosen because the host records it and nothing acts on it. A device that
/// presses `a` presses it into whatever window has focus, which on a machine
/// where somebody is working is a way to lose work. This one is visible in
/// `xset q` and in `/sys/class/leds/*::scrolllock` and disturbs nothing —
/// which also means it can be verified from a shell, with nobody watching a
/// screen.
const KEY_SCROLL_LOCK: u8 = 0x47;

/// The byte that asks for a keypress. Sent over exp118's OUT endpoint.
const CMD_PRESS: u8 = b'k';

static PACKETS: AtomicU32 = AtomicU32::new(0);
static BYTES: AtomicU32 = AtomicU32::new(0);

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

/// exp118's loop unchanged: it owns the `Receiver`, so it does both of the
/// jobs the `Receiver` makes possible.
#[embassy_executor::task]
async fn console_task(
    control: ControlChanged<'static>,
    mut receiver: Receiver<'static, usb_reboot::UsbDriver>,
    mut keyboard: HidWriter<'static, usb_reboot::UsbDriver, { HID_REPORT_BYTES as usize }>,
) -> ! {
    let mut buf = [0u8; PACKET];

    loop {
        match select(control.control_changed(), receiver.read_packet(&mut buf)).await {
            Either::First(()) => {
                let rate = receiver.line_coding().data_rate();
                log!(
                    "control: {} baud, DTR {}",
                    rate,
                    if receiver.dtr() { "on" } else { "off" }
                );
                usb_reboot::reboot_if_requested(rate).await;
            }

            Either::Second(Ok(0)) => {
                log!("zero-length packet — not counted, nobody sent it");
            }

            Either::Second(Ok(n)) => {
                let data = &buf[..n];
                let seq = PACKETS.fetch_add(1, Ordering::Relaxed) + 1;
                BYTES.fetch_add(n as u32, Ordering::Relaxed);
                log!("in #{}: {} bytes", seq, n);
                for (i, row) in data.chunks(ROW).enumerate() {
                    log!("  {:04x}  {} {}", i * ROW, Hex(row), Printable(row));
                }

                if data[0] == CMD_PRESS {
                    press(&mut keyboard).await;
                }
            }

            Either::Second(Err(_)) => {
                receiver.wait_connection().await;
                log!("interface enabled again — listening");
            }
        }
    }
}

/// One press and one release of Scroll Lock.
///
/// Both halves, and the release is not optional. A HID keyboard reports the
/// set of keys currently held, not events — so a report with a key in it and
/// no report after it is a key held down forever, and the host's autorepeat
/// takes it from there.
///
/// This runs inside the console task, which owns the `Receiver` and therefore
/// cannot be doing anything else meanwhile. `write_serialize` waits for the
/// host to poll the interrupt endpoint, which with `HID_POLL_MS` of 64 is up
/// to 64 ms per report — so pressing a key costs this firmware up to an eighth
/// of a second of not listening to its own console. Harmless here, and worth
/// knowing before putting a keypress somewhere that matters: the control-line
/// event latches, so a reboot request arriving mid-press is not lost, only
/// delayed.
async fn press(
    keyboard: &mut HidWriter<'static, usb_reboot::UsbDriver, { HID_REPORT_BYTES as usize }>,
) {
    let down = KeyboardReport {
        modifier: 0,
        reserved: 0,
        leds: 0,
        keycodes: [KEY_SCROLL_LOCK, 0, 0, 0, 0, 0],
    };
    let up = KeyboardReport { keycodes: [0; 6], ..down };

    match keyboard.write_serialize(&down).await {
        Ok(()) => {}
        Err(_) => {
            // No host collecting the reports. Say so rather than pressing into
            // the void: the whole point of this key is that it is observable,
            // and "nothing happened" with no explanation is the failure this
            // repository keeps meeting.
            log!("key: the host is not collecting HID reports — nothing pressed");
            return;
        }
    }
    let _ = keyboard.write_serialize(&up).await;
    log!("key: pressed and released Scroll Lock (usage {:#04x})", KEY_SCROLL_LOCK);
}

#[embassy_executor::task]
async fn idle_task() -> ! {
    loop {
        Timer::after(IDLE_REPORT).await;
        let packets = PACKETS.load(Ordering::Relaxed);
        if packets == 0 {
            log!("idle: nothing received. Send 'k' to press Scroll Lock — yi26 send k");
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

/// Declares the keyboard interface. Called from one of two places, and that
/// is the point — see the comment at the call sites.
fn make_keyboard(
    builder: &mut Builder<'static, Driver<'static, USB>>,
    state: &'static mut HidState<'static>,
    report_descriptor: &'static [u8],
) -> HidWriter<'static, usb_reboot::UsbDriver, { HID_REPORT_BYTES as usize }> {
    HidWriter::new(
        builder,
        state,
        HidConfig {
            report_descriptor,
            request_handler: None,
            poll_ms: HID_POLL_MS,
            max_packet_size: HID_REPORT_BYTES,

            // Boot protocol, which is a claim about what this interface can do
            // before any driver has read the report descriptor: a BIOS or a
            // bootloader can drive it with a fixed eight-byte layout. That is
            // free here because `KeyboardReport` already has that layout, and
            // it is the difference between a keyboard that works in a firmware
            // setup screen and one that does not.
            hid_subclass: HidSubclass::Boot,
            hid_boot_protocol: HidBootProtocol::Keyboard,
        },
    )
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let p = embassy_rp::init(Default::default());
    let mut led = Output::new(p.PIN_25, Level::Low);

    let driver = Driver::new(p.USB, Irqs);

    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some("exp121 composite hid");
    config.serial_number = Some("121");

    // Unchanged from every other experiment here, and now finally true of more
    // than one function.
    config.device_class = 0xef;
    config.device_sub_class = 0x02;
    config.device_protocol = 0x01;
    config.composite_with_iads = true;

    // The configuration descriptor now has to hold a third interface, its HID
    // descriptor, its endpoint, and a second Interface Association Descriptor.
    // 256 bytes was ample for one function; it is worth knowing that running
    // out here is not an error you get told about — the builder panics, which
    // on this chip means a board that enumerates as nothing at all.
    static CONFIG_DESCRIPTOR: StaticCell<[u8; 256]> = StaticCell::new();
    static BOS_DESCRIPTOR: StaticCell<[u8; 256]> = StaticCell::new();
    static CONTROL_BUF: StaticCell<[u8; 64]> = StaticCell::new();
    static ACM_STATE: StaticCell<State> = StaticCell::new();
    static HID_STATE: StaticCell<HidState> = StaticCell::new();

    let mut builder = Builder::new(
        driver,
        config,
        CONFIG_DESCRIPTOR.init([0; 256]),
        BOS_DESCRIPTOR.init([0; 256]),
        &mut [],
        CONTROL_BUF.init([0; 64]),
    );

    // Build order decides every interface and endpoint number, and this is the
    // whole of the difference between the two builds.
    //
    // The default puts the new function last, so the CDC pair keeps the
    // numbers every other experiment found — a first descriptor change that is
    // one addition rather than an addition plus a renumbering.
    //
    // `--features hid-first` reverses it. Nothing else changes: same
    // descriptors, same firmware, same behaviour. Everything in this
    // repository keeps working across both, because everything here finds
    // interfaces by class and endpoints by direction. That is not a style
    // preference; it is the reason the browser pages did not have to be
    // touched when this experiment landed.
    //
    // The report descriptor is generated rather than hand-written. Hand-rolling
    // one is a fine exercise and a poor first descriptor change: a malformed
    // report descriptor is accepted by the builder and rejected by the host,
    // which looks like a hardware fault. The bytes are printed at boot so they
    // are still something you can read.
    let hid_report = KeyboardReport::desc();

    #[cfg(feature = "hid-first")]
    let hid = make_keyboard(&mut builder, HID_STATE.init(HidState::new()), hid_report);

    let class = CdcAcmClass::new(&mut builder, ACM_STATE.init(State::new()), PACKET as u16);

    #[cfg(not(feature = "hid-first"))]
    let hid = make_keyboard(&mut builder, HID_STATE.init(HidState::new()), hid_report);

    let usb = builder.build();
    spawner.spawn(usb_task(usb).unwrap());

    let (sender, receiver, control) = class.split_with_control();
    spawner.spawn(log_task(sender).unwrap());
    spawner.spawn(console_task(control, receiver, hid).unwrap());
    spawner.spawn(idle_task().unwrap());

    log!("exp121 up. Two functions on one cable, and nothing is pressed.");
    log!(
        "HID report descriptor: {} bytes, first eight: {}",
        hid_report.len(),
        Hex(&hid_report[..hid_report.len().min(8)])
    );

    loop {
        led.set_high();
        Timer::after(Duration::from_millis(50)).await;
        led.set_low();
        Timer::after(Duration::from_millis(950)).await;
    }
}
