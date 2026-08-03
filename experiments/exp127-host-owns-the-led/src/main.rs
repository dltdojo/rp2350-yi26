//! exp127 — the host owns the LED.
//!
//! exp118 taught this firmware to listen, and then printed what arrived. It
//! deliberately stopped there: bytes went in, a hex dump came out, and the
//! board itself was unchanged by anything the host said.
//!
//! This one lets the host change it. Send `0x01` and the LED comes on; send
//! `0x00` and it goes off. That is the whole protocol, and it is the first
//! time in this repository that a host is the owner of a piece of the
//! device's state rather than an observer of it.
//!
//! # Why one byte needs no framing, and what that is hiding
//!
//! exp118 established that USB delivers packets, not messages: a hundred
//! bytes written once arrive as `64` and then `36`. Any firmware that wants
//! *messages* has to define what one is and reassemble them.
//!
//! This firmware does not have that problem, and the reason is worth being
//! precise about, because it is easy to mistake for "USB is simple after
//! all". A one-byte command cannot be split, because the endpoint's packet
//! size is 64 and one is less than 64. The framing problem has not been
//! solved here. It has been **avoided by staying underneath
//! `wMaxPacketSize`**.
//!
//! So this firmware refuses multi-byte packets rather than guessing at them.
//! A packet of six bytes is not `led on` with a typo; it is a message this
//! protocol has no way to delimit, and pretending otherwise would teach the
//! wrong lesson. Where the boundary actually lives — on a wire, in the bus's
//! electrical states, in the protocol layer, or nowhere at all — is the
//! subject of the table in this experiment's README.
//!
//! # The LED cannot be two things at once
//!
//! Every firmware here since exp103 blinks the LED as a heartbeat, and that
//! blink has been doing real work: it is how you know the board is alive
//! without opening a terminal.
//!
//! The moment the host can turn the LED off, that stops being true. A dark
//! LED now means one of:
//!
//! - the host turned it off,
//! - the firmware crashed,
//! - the firmware never started.
//!
//! and nothing on the board can tell you which. This is not a wart in the
//! design; it is what happens whenever a status indicator and a controllable
//! output are the same resource, and it happens in real products constantly.
//!
//! This firmware does not dodge it. The heartbeat runs until the first
//! command arrives and then **stops for good** — the LED belongs to the host
//! from that point, and the log becomes the only proof of life. The idle line
//! says so in as many words, every five seconds, because a reader who has
//! just turned the LED off deserves to be told what they gave up.
//!
//! # Proving the pin moved, and the two registers that answer differently
//!
//! "The firmware says `led on`" proves that a byte was received and a branch
//! was taken. It does not prove that anything electrical happened. The board
//! is not visible from a log, and this repository's rule is that the outcome
//! is what gets checked, not the return value.
//!
//! The RP2350 offers two different answers, and the difference is the point:
//!
//! ```text
//!   SIO GPIO_OUT   what I last wrote     embassy-rp: Flex::is_set_high()
//!   SIO GPIO_IN    what the pad is at    embassy-rp: Flex::is_high()
//! ```
//!
//! `Output::get_output_level()` reads the first one. It cannot fail in any
//! interesting way: it hands back the value that was just stored, so a log
//! line built from it is a rephrasing of the command, not evidence about it.
//!
//! `GPIO_IN` is the pad. Reading it back on an output pin works because
//! `Flex::new` turns the input buffer on unconditionally — `w.set_ie(true)`,
//! `embassy-rp-0.10.0/src/gpio.rs:622` — and it is the reason this firmware
//! uses [`Flex`] where every experiment before it used `Output`. That one
//! substitution is the difference between a log that repeats itself and a log
//! that has checked.
//!
//! It still does not prove the LED **lit**. An unpopulated LED, a dead one,
//! or a board that wires its LED to a different GPIO all read back exactly
//! like success. That last gap closes with an eye and nothing else, which is
//! why this experiment's `Expected output` has a line in it that no script
//! produced.

#![no_std]
#![no_main]

use core::sync::atomic::{AtomicBool, AtomicU32, Ordering};

use embassy_executor::Spawner;
use embassy_futures::select::{select3, Either3};
use embassy_rp::bind_interrupts;
use embassy_rp::gpio::Flex;
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

/// One CDC packet. `read_packet` requires a buffer at least this large, and
/// this number is also the whole reason a one-byte command is easy: a command
/// shorter than a packet can never arrive in two pieces.
const PACKET: usize = 64;

/// The two commands. There is no third.
const CMD_OFF: u8 = 0x00;
const CMD_ON: u8 = 0x01;

/// Heartbeat shape, while the firmware still owns the LED.
const BLINK_ON: Duration = Duration::from_millis(50);
const BLINK_OFF: Duration = Duration::from_millis(950);

/// What the heartbeat branch waits for once it has nothing left to do.
///
/// The select loop below needs three futures whether or not the third one is
/// still useful, so after the host takes the LED this branch wakes up once a
/// second and goes straight back to sleep. A second of granularity costs
/// nothing measurable and keeps the loop one shape instead of two.
const IDLE_TICK: Duration = Duration::from_secs(1);

/// How often the idle line repeats.
const IDLE_REPORT: Duration = Duration::from_secs(5);

/// Cycles to wait between writing a pin and reading it back.
///
/// `GPIO_IN` is not a mirror of `GPIO_OUT`; it is the pad, sampled through the
/// input synchroniser, which is two `clk_sys` flip-flops deep. A store
/// followed immediately by a load can therefore read the *old* level and
/// produce a log line saying `OUT high, pad low` — a hardware fault that did
/// not happen. Roughly sixty cycles at 150 MHz is 400 ns, which is far more
/// than the synchroniser needs and far less than anyone can see.
const SETTLE_CYCLES: u32 = 64;

/// Counters and state, shared with the reporter task.
///
/// Plain atomics, no channel: the console task writes and the reporter only
/// reads, so there is nothing here a lock would protect.
static COMMANDS: AtomicU32 = AtomicU32::new(0);
static REFUSED: AtomicU32 = AtomicU32::new(0);
static HOST_OWNS: AtomicBool = AtomicBool::new(false);
static LED_ON: AtomicBool = AtomicBool::new(false);

#[embassy_executor::task]
async fn usb_task(mut device: UsbDevice<'static, Driver<'static, USB>>) -> ! {
    device.run().await
}

#[embassy_executor::task]
async fn log_task(sender: Sender<'static, usb_reboot::UsbDriver>) -> ! {
    usb_log::run(sender).await
}

/// Reads the pad and reports it beside what was written.
///
/// Two values, always both, even though they agree on every healthy board.
/// Printing only the pad would leave a disagreement unattributable, and
/// printing only the register would be exp103 with extra words.
fn readback(led: &Flex<'static>) -> (&'static str, &'static str) {
    cortex_m::asm::delay(SETTLE_CYCLES);
    let wrote = if led.is_set_high() { "high" } else { "low" };
    let pad = if led.is_high() { "high" } else { "low" };
    (wrote, pad)
}

/// The task this experiment exists for.
///
/// It owns three things that all want to happen at once — the reboot watcher
/// from exp105, the reader from exp118, and the heartbeat from exp103 — and
/// it owns them for exp118's reason: there is exactly one `Receiver`, and now
/// exactly one LED as well. The shape is `select3` because the alternative is
/// two tasks fighting over one pin.
#[embassy_executor::task]
async fn console_task(
    control: ControlChanged<'static>,
    mut receiver: Receiver<'static, usb_reboot::UsbDriver>,
    mut led: Flex<'static>,
) -> ! {
    let mut buf = [0u8; PACKET];
    let mut lit = false;

    loop {
        // The heartbeat's next deadline, rebuilt every iteration. A `Timer`
        // dropped by `select3` loses its progress, unlike the latching
        // control-change flag exp118 checked the source for — so sending a
        // burst of commands visibly disturbs the blink. That is a real
        // consequence of cancellation and not worth engineering away: after
        // the first command there is no blink left to disturb.
        let delay = if HOST_OWNS.load(Ordering::Relaxed) {
            IDLE_TICK
        } else if lit {
            BLINK_ON
        } else {
            BLINK_OFF
        };

        match select3(
            control.control_changed(),
            receiver.read_packet(&mut buf),
            Timer::after(delay),
        )
        .await
        {
            // Unchanged from exp118: the 1200-baud reboot has to keep
            // working, or the next person to flash this board needs a hand on
            // the BOOTSEL button.
            Either3::First(()) => {
                let rate = receiver.line_coding().data_rate();
                log!(
                    "control: {} baud, DTR {}",
                    rate,
                    if receiver.dtr() { "on" } else { "off" }
                );
                usb_reboot::reboot_if_requested(rate).await;
            }

            // exp118 established what this is: the endpoint completing empty
            // as it is enabled, before any host could have typed anything.
            // Not a command, and not counted as a refusal either.
            Either3::Second(Ok(0)) => {
                log!("zero-length packet — nobody sent it");
            }

            Either3::Second(Ok(1)) => {
                let byte = buf[0];
                match byte {
                    CMD_OFF | CMD_ON => {
                        let on = byte == CMD_ON;
                        if on {
                            led.set_high();
                        } else {
                            led.set_low();
                        }
                        LED_ON.store(on, Ordering::Relaxed);
                        let n = COMMANDS.fetch_add(1, Ordering::Relaxed) + 1;
                        let first = !HOST_OWNS.swap(true, Ordering::Relaxed);

                        let (wrote, pad) = readback(&led);
                        log!(
                            "cmd #{}: 0x{:02x} led {} (OUT {}, pad {})",
                            n,
                            byte,
                            if on { "on" } else { "off" },
                            wrote,
                            pad
                        );

                        // Said once, at the moment it becomes true, and then
                        // repeated by the idle line for anyone who arrives
                        // afterwards.
                        if first {
                            log!("heartbeat stopped — the LED is the host's now");
                        }
                    }
                    other => {
                        let n = REFUSED.fetch_add(1, Ordering::Relaxed) + 1;
                        log!("0x{:02x} is not a command (refused {})", other, n);
                        log!("  0x00 = off, 0x01 = on. Nothing else.");
                    }
                }
            }

            // Refused, not parsed. This firmware has no way to say where one
            // message ends and the next begins, so `led on` is six bytes it
            // cannot delimit rather than a command it can almost understand.
            Either3::Second(Ok(n)) => {
                REFUSED.fetch_add(1, Ordering::Relaxed);
                log!("{} bytes in one packet — one byte per command here", n);
                log!("  nothing reassembles them; that needs framing");
            }

            Either3::Second(Err(_)) => {
                receiver.wait_connection().await;
                log!("interface enabled again — listening");
            }

            // The heartbeat, while there still is one.
            Either3::Third(()) => {
                if !HOST_OWNS.load(Ordering::Relaxed) {
                    lit = !lit;
                    if lit {
                        led.set_high();
                    } else {
                        led.set_low();
                    }
                }
            }
        }
    }
}

/// Says what state the board is in, on a loop, forever.
///
/// After the host takes the LED this line is the **only** thing distinguishing
/// a working board from a dead one, which is why it repeats rather than being
/// printed once at the moment of takeover.
#[embassy_executor::task]
async fn idle_task() -> ! {
    loop {
        Timer::after(IDLE_REPORT).await;

        if !HOST_OWNS.load(Ordering::Relaxed) {
            log!("idle: heartbeat, no command yet — try  yi26 send '\\x01'");
            continue;
        }

        log!(
            "idle: led {}, host-owned after {} command{} ({} refused)",
            if LED_ON.load(Ordering::Relaxed) { "on" } else { "off" },
            COMMANDS.load(Ordering::Relaxed),
            if COMMANDS.load(Ordering::Relaxed) == 1 { "" } else { "s" },
            REFUSED.load(Ordering::Relaxed)
        );
        log!("  this line is now the only proof the firmware is alive");
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let p = embassy_rp::init(Default::default());

    // `Flex`, not `Output` — and this is the only line in the firmware that
    // the readback depends on. `Output` can tell you what it last wrote;
    // `Flex` can also tell you what the pad is at. See the module docs.
    //
    // Board-specific: the LED's GPIO. One line, clearly marked.
    let mut led = Flex::new(p.PIN_25);
    led.set_low();
    led.set_as_output();

    let driver = Driver::new(p.USB, Irqs);

    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some("exp127 host owns the led");
    config.serial_number = Some("127");
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

    // Byte-for-byte the descriptors exp115 captured, exactly as in exp118. A
    // host that can command this board sees no new interface and no new
    // endpoint: the OUT endpoint that carries `0x01` is the one that has been
    // in every configuration descriptor since exp104.
    let class = CdcAcmClass::new(&mut builder, ACM_STATE.init(State::new()), PACKET as u16);
    let usb = builder.build();
    spawner.spawn(usb_task(usb).unwrap());

    let (sender, receiver, control) = class.split_with_control();
    spawner.spawn(log_task(sender).unwrap());
    spawner.spawn(console_task(control, receiver, led).unwrap());
    spawner.spawn(idle_task().unwrap());

    log!("exp127 up. The LED is the firmware's until the host takes it.");
}
