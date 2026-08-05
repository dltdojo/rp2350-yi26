//! exp148 — a wire with no address.
//!
//! The first experiment on the network road, and it deliberately stops one step
//! short of a network. It builds a **CDC-NCM virtual Ethernet link** to the
//! host, runs `embassy-net` over it, asks for an address by DHCP — and then
//! reports, on the LED, exactly how far that got.
//!
//! Two things happen on the way to "networking works", and they are usually
//! collapsed into one:
//!
//! 1. **A driver on the host claims the interface.** Until that happens the
//!    board is a device nobody is talking to. NCM makes this observable: the
//!    host selects a non-zero alt setting on the data interface when its driver
//!    binds, and until it does, `Stack::is_link_up()` is false.
//! 2. **Somebody hands out an address.** DHCP is a *conversation*, and a
//!    conversation needs the other party to be a server. That is a property of
//!    the host, not of this firmware.
//!
//! Separating them is the entire experiment, because on the two hosts this
//! repository has, they come apart in different places:
//!
//! ```text
//!   Ubuntu, connection sharing on    link up, address leased    -> fast blink
//!   Ubuntu, sharing NOT turned on    link up, no address        -> slow blink
//!   a phone                          ??? — that is the question
//! ```
//!
//! The phone is why the LED exists. On a phone there is no log to read, no
//! `ip addr` to run, and nothing to install; there is a board, a cable, and
//! somebody looking at it. So the readout is a rate of blinking, the same
//! choice [exp147](../../exp147-two-firmwares-one-phone/) made and for the same
//! reason — and here it is doubly deliberate, because
//! [`docs/debugging-on-a-phone.md`](../../docs/debugging-on-a-phone.md) records
//! that an LED is the one instrument a sleeping phone cannot interrupt.
//!
//! The CDC-ACM log is still here, unchanged, and it is where the desktop half
//! of this experiment reads its answer. `yi26 log` remains the instrument;
//! the LED is the product.

#![no_std]
#![no_main]

use embassy_executor::Spawner;
use embassy_futures::select::{select, Either};
use embassy_net::{Config as NetConfig, Runner as NetRunner, Stack, StackResources};
use embassy_rp::bind_interrupts;
use embassy_rp::gpio::{Level, Output};
use embassy_rp::peripherals::{TRNG, USB};
use embassy_rp::trng::{Config as TrngConfig, InterruptHandler as TrngInterruptHandler, Trng};
use embassy_rp::usb::{Driver, InterruptHandler};
use embassy_time::{Duration, Instant, Timer};
use embassy_usb::class::cdc_acm::{CdcAcmClass, ControlChanged, Receiver, Sender, State as AcmState};
use embassy_usb::class::cdc_ncm::embassy_net::{Device, Runner as NcmRunner, State as NetDeviceState};
use embassy_usb::class::cdc_ncm::{CdcNcmClass, State as NcmState};
use embassy_usb::{Builder, Config as UsbConfig, UsbDevice};
use panic_halt as _;
use rp2350_linker as _;
use static_cell::StaticCell;
use usb_log::log;

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
    TRNG_IRQ => TrngInterruptHandler<TRNG>;
});

const PACKET: usize = 64;

/// One Ethernet frame, header and all: 14 bytes of header + 1500 of payload.
/// `embassy-net` sizes its packet buffers from this, so it is the number that
/// decides how much SRAM the link costs — four buffers each way below.
const MTU: usize = 1514;

/// Two locally administered addresses — the `0x02` bit in the first byte means
/// "made up locally, not bought from the IEEE". A real vendor's MAC starts with
/// an OUI it paid for; a device that invents one has to set this bit instead,
/// or it is claiming a range that belongs to somebody.
///
/// Both ends of a CDC-NCM link need one: the class descriptor tells the host
/// what address to give *its* end, and `into_embassy_net_device` sets ours.
const HOST_MAC: [u8; 6] = [0x02, 0x26, 0x00, 0x00, 0x01, 0x48];
const OUR_MAC: [u8; 6] = [0x02, 0x26, 0x00, 0x00, 0x02, 0x48];

/// How the LED reports each of the three states. Faster is further along.
const BLINK_LINK: Duration = Duration::from_millis(500);
const BLINK_ADDRESS: Duration = Duration::from_millis(100);
/// How often the LED loop re-reads the stack. Also how long a dark LED stays
/// dark before it looks again.
const POLL: Duration = Duration::from_millis(50);

const REPORT_EVERY: Duration = Duration::from_secs(5);

/// Clock cycles between two ring-oscillator samples. exp109's number, not
/// embassy-rp's — see where it is used.
const TRNG_SAMPLE_COUNT: u32 = 1000;


#[embassy_executor::task]
async fn usb_task(mut device: UsbDevice<'static, Driver<'static, USB>>) -> ! {
    device.run().await
}

#[embassy_executor::task]
async fn log_task(sender: Sender<'static, usb_reboot::UsbDriver>) -> ! {
    usb_log::run(sender).await
}

/// The 1200-baud watcher. Kept in every firmware on this road for the same
/// reason as everywhere else: without it the next flash of this board needs a
/// physical hand on BOOTSEL, and on the phone bench there is no way to ask for
/// one.
#[embassy_executor::task]
async fn control_task(
    control: ControlChanged<'static>,
    mut receiver: Receiver<'static, usb_reboot::UsbDriver>,
) -> ! {
    let mut buf = [0u8; PACKET];
    loop {
        match select(control.control_changed(), receiver.read_packet(&mut buf)).await {
            Either::First(()) => {
                usb_reboot::reboot_if_requested(receiver.line_coding().data_rate()).await;
            }
            Either::Second(_) => {}
        }
    }
}

/// Moves NTBs — NCM Transfer Blocks — between the USB endpoints and the network
/// stack, and sets the link state while it is at it: down until
/// `wait_connection()` returns, up afterwards.
///
/// That call is the observable this experiment is built around. It returns when
/// the host enables the data endpoints, which a host only does once one of its
/// drivers has decided to own this interface.
#[embassy_executor::task]
async fn ncm_task(runner: NcmRunner<'static, Driver<'static, USB>, MTU>) -> ! {
    runner.run().await
}

#[embassy_executor::task]
async fn net_task(mut runner: NetRunner<'static, Device<'static, MTU>>) -> ! {
    runner.run().await
}

/// The desktop half of the readout: the same three states as the LED, in words,
/// with the leased address when there is one.
///
/// It prints on every *change*, and then every five seconds regardless, because
/// a log that only prints on change is indistinguishable from a log that has
/// died — and the state this experiment most expects to see is one that never
/// changes again.
#[embassy_executor::task]
async fn report_task(stack: Stack<'static>) -> ! {
    let started = Instant::now();
    let mut last: Option<(bool, bool)> = None;
    let mut next_idle = Instant::now() + REPORT_EVERY;

    loop {
        let now = (stack.is_link_up(), stack.is_config_up());
        let changed = last != Some(now);

        if changed || Instant::now() >= next_idle {
            let ms = (Instant::now() - started).as_millis();
            match now {
                (false, _) => {
                    log!("{} ms  link DOWN — no host driver has claimed the NCM data interface", ms);
                }
                (true, false) => {
                    log!("{} ms  link UP, no address — DHCP is asking and nobody is answering", ms);
                }
                (true, true) => match stack.config_v4() {
                    Some(cfg) => {
                        let a = cfg.address.address().octets();
                        log!(
                            "{} ms  link UP, address {}.{}.{}.{}/{}",
                            ms,
                            a[0],
                            a[1],
                            a[2],
                            a[3],
                            cfg.address.prefix_len()
                        );
                        match cfg.gateway {
                            Some(g) => {
                                let g = g.octets();
                                log!("        gateway {}.{}.{}.{}", g[0], g[1], g[2], g[3]);
                            }
                            None => log!("        no gateway — a link, not a route to anywhere"),
                        }
                    }
                    // is_config_up() and config_v4() are read one after the
                    // other, so a lease that expires in between lands here.
                    None => log!("{} ms  link UP, address just went away", ms),
                },
            }
            last = Some(now);
            next_idle = Instant::now() + REPORT_EVERY;
        }

        Timer::after(POLL).await;
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let p = embassy_rp::init(Default::default());
    let mut led = Output::new(p.PIN_25, Level::Low);
    let driver = Driver::new(p.USB, Irqs);

    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some("exp148 a wire with no address");
    config.serial_number = Some("148");
    config.device_class = 0xef;
    config.device_sub_class = 0x02;
    config.device_protocol = 0x01;
    config.composite_with_iads = true;

    static CONFIG_DESCRIPTOR: StaticCell<[u8; 256]> = StaticCell::new();
    static BOS_DESCRIPTOR: StaticCell<[u8; 256]> = StaticCell::new();
    static CONTROL_BUF: StaticCell<[u8; 128]> = StaticCell::new();
    static ACM_STATE: StaticCell<AcmState> = StaticCell::new();
    static NCM_STATE: StaticCell<NcmState> = StaticCell::new();

    let mut builder = Builder::new(
        driver,
        config,
        CONFIG_DESCRIPTOR.init([0; 256]),
        BOS_DESCRIPTOR.init([0; 256]),
        &mut [],
        CONTROL_BUF.init([0; 128]),
    );

    // Order matters only in that the log interface comes first, so the port a
    // person opens is the one that talks.
    let acm = CdcAcmClass::new(&mut builder, ACM_STATE.init(AcmState::new()), PACKET as u16);
    let ncm = CdcNcmClass::new(
        &mut builder,
        NCM_STATE.init(NcmState::new()),
        HOST_MAC,
        PACKET as u16,
    );

    let usb = builder.build();
    spawner.spawn(usb_task(usb).unwrap());

    let (sender, receiver, control) = acm.split_with_control();
    spawner.spawn(log_task(sender).unwrap());
    spawner.spawn(control_task(control, receiver).unwrap());

    // Four buffers each way. Each one is a whole MTU, so this line is worth
    // about 12 KiB of SRAM — the price of the link, paid whether or not
    // anything ever arrives.
    static NET_DEVICE_STATE: StaticCell<NetDeviceState<MTU, 4, 4>> = StaticCell::new();
    let (ncm_runner, device) =
        ncm.into_embassy_net_device::<MTU, 4, 4>(NET_DEVICE_STATE.init(NetDeviceState::new()), OUR_MAC);
    spawner.spawn(ncm_task(ncm_runner).unwrap());

    // The stack wants a seed it cannot predict — it goes into TCP sequence
    // numbers and into the DHCP transaction ID. exp109 established that this
    // chip has a real TRNG, so there is no reason to fake it here. It is read
    // once, at boot, and the peripheral is then dropped.
    // `sample_count` is set, and NOT left at the default, because
    // [exp109](../../exp109-hardware-trng/) measured what the default does on
    // this board. embassy-rp ships 25 clock cycles between ring-oscillator
    // samples; at that spacing consecutive samples are still correlated, the
    // TRNG's own health tests reject the block, and it starts over. exp109
    // timed three consecutive 64-bit fills at **0.38 s, 31.4 s and 14.5 s**.
    // At 1000 it is 5–6 ms, every time.
    //
    // This experiment paid to rediscover that. Boots looked dead — USB
    // enumerated, the 1200-baud watcher answered, and nothing spawned after
    // this line ever ran — because the log was read seven seconds after a boot
    // that spent thirty in here. Nothing was hung; everything was waiting, and
    // a wait long enough to be mistaken for a hang is worse than a crash.
    //
    // Sampling more slowly does not make the bits better. It makes them
    // *cheaper to get*, which is a different claim and exp109 is careful about
    // it.
    //
    // And the rule the detour paid for, which outlives this line:
    // **nothing may block the executor before USB is up.** `.await` here leaves
    // `usb_task` free to enumerate and `control_task` free to answer the
    // 1200-baud touch, so however long this takes the board can still be
    // reflashed. The blocking version does not, and a board that cannot
    // enumerate cannot be recovered without a hand on BOOTSEL — which, on the
    // bench this firmware is aimed at, means a phone and no button anybody is
    // going to reach.
    let mut trng_config = TrngConfig::default();
    trng_config.sample_count = TRNG_SAMPLE_COUNT;
    let mut trng = Trng::new(p.TRNG, Irqs, trng_config);
    let mut seed = [0u8; 8];
    trng.fill_bytes(&mut seed).await;

    static RESOURCES: StaticCell<StackResources<3>> = StaticCell::new();
    let (stack, net_runner) = embassy_net::new(
        device,
        // Not a static address. A static address would make this experiment
        // succeed on a desk by fiat and teach nothing: the board would "have an
        // address" whether or not anything on the other end agreed. Asking is
        // the point — the answer is what differs between a laptop and a phone.
        NetConfig::dhcpv4(Default::default()),
        RESOURCES.init(StackResources::new()),
        u64::from_le_bytes(seed),
    );
    spawner.spawn(net_task(net_runner).unwrap());
    spawner.spawn(report_task(stack).unwrap());

    log!("exp148 up. CDC-ACM for this log, CDC-NCM for the link.");
    log!("  our MAC {:02x}:{:02x}:{:02x}:{:02x}:{:02x}:{:02x}, the host's end {:02x}:{:02x}:{:02x}:{:02x}:{:02x}:{:02x}",
        OUR_MAC[0], OUR_MAC[1], OUR_MAC[2], OUR_MAC[3], OUR_MAC[4], OUR_MAC[5],
        HOST_MAC[0], HOST_MAC[1], HOST_MAC[2], HOST_MAC[3], HOST_MAC[4], HOST_MAC[5]);
    log!("  LED: dark = no link, slow = link but no address, fast = address.");

    // In `main` and not in a task, for exp147's reason: on the bench this
    // experiment is aimed at, the LED is the only instrument, and it should be
    // the last thing in this firmware to stop moving.
    loop {
        match (stack.is_link_up(), stack.is_config_up()) {
            // Dark, and checking often enough that plugging into a host feels
            // instant rather than like a bug.
            (false, _) => {
                led.set_low();
                Timer::after(POLL).await;
            }
            (true, false) => blink(&mut led, BLINK_LINK).await,
            (true, true) => blink(&mut led, BLINK_ADDRESS).await,
        }
    }
}

/// One on/off cycle. Split out so the state is re-read every half-cycle: a
/// board that gets its lease mid-blink speeds up within the half second, rather
/// than finishing a slow cycle first and looking like it did not notice.
async fn blink(led: &mut Output<'static>, half: Duration) {
    led.set_high();
    Timer::after(half).await;
    led.set_low();
    Timer::after(half).await;
}
