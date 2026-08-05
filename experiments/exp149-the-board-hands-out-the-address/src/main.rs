//! exp149 — the board hands out the address.
//!
//! [exp148](../../exp148-a-wire-with-no-address/) got a link and stopped, because
//! nobody on either end would give out an address. That was measured on two very
//! different hosts and they behaved identically: Ubuntu's NetworkManager and a
//! Pixel 9a both run a DHCP **client** on a new USB Ethernet interface, and so
//! did the board. Two clients, waiting for each other.
//!
//! A laptop can be told to be the server — one `nmcli` line. **A phone cannot**;
//! the setting does not exist. So if a board is to be reachable from the machine
//! most people actually own, the board is the one that has to answer.
//!
//! `embassy-net` has no DHCP server; smoltcp's `dhcpv4` socket is a client. So
//! this firmware opens a UDP socket on port 67 and speaks the four packets
//! itself. The protocol lives in [`dhcp`](../../../crates/dhcp/), which has no
//! socket in it and is tested on a host; this file is the part that owns the
//! endpoint.
//!
//! # What changed from exp148, and why the LED means something else
//!
//! The board now has a **static** address — it is the server, so it cannot ask
//! for one. That makes `is_config_up()` true from boot, which would leave
//! exp148's LED stuck on "fast" saying nothing at all.
//!
//! So the LED reports the **client's** progress instead, which is what is being
//! measured here:
//!
//! ```text
//!   dark   no link — no host driver has claimed the NCM interface
//!   slow   link up, and nobody has asked for an address
//!   fast   a client asked, and took what it was offered
//! ```
//!
//! Two things worth knowing about the answer it gives:
//!
//! **Every reply goes to 255.255.255.255.** The obvious alternative — unicast
//! to the address being offered — cannot work, because the client does not own
//! that address yet and so will not answer an ARP for it. A real server solves
//! that by injecting an ARP entry it was never told. Broadcasting is legal, it
//! is what the `BROADCAST` flag in the reply announces, and it makes the whole
//! problem disappear.
//!
//! **The offer contains no router and no DNS.** Both are conventional, and both
//! would be false: this board is one end of a cable and routes nothing. The
//! risk that is worth avoiding is a phone deciding a USB link is its way to the
//! internet and losing its actual way to the internet. See the README.

#![no_std]
#![no_main]

use embassy_executor::Spawner;
use embassy_futures::select::{select, Either};
use embassy_net::udp::{PacketMetadata, UdpSocket};
use embassy_net::{
    Config as NetConfig, IpAddress, IpEndpoint, Ipv4Address, Ipv4Cidr, Runner as NetRunner,
    StackResources, StaticConfigV4,
};
use embassy_rp::bind_interrupts;
use embassy_rp::gpio::{Level, Output};
use embassy_rp::peripherals::{TRNG, USB};
use embassy_rp::trng::{Config as TrngConfig, InterruptHandler as TrngInterruptHandler, Trng};
use embassy_rp::usb::{Driver, InterruptHandler};
use embassy_sync::blocking_mutex::raw::CriticalSectionRawMutex;
use embassy_sync::signal::Signal;
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
const MTU: usize = 1514;

const HOST_MAC: [u8; 6] = [0x02, 0x26, 0x00, 0x00, 0x01, 0x49];
const OUR_MAC: [u8; 6] = [0x02, 0x26, 0x00, 0x00, 0x02, 0x49];

/// The whole network. `.1` is this board and `.2` is whatever is on the other
/// end of the cable — one address in the pool, because a USB link has one host
/// on it. `192.168.7.0/24` is private space that nothing else is likely to be
/// using at the same moment as a cable plugged into one board.
const BOARD_IP: [u8; 4] = [192, 168, 7, 1];
const CLIENT_IP: [u8; 4] = [192, 168, 7, 2];
const MASK: [u8; 4] = [255, 255, 255, 0];
const PREFIX: u8 = 24;

/// An hour. Long enough that nothing renews during an experiment, short enough
/// that a client which loses the board does not remember the address for a day.
const LEASE_SECONDS: u32 = 3600;

const BLINK_LINK: Duration = Duration::from_millis(500);
const BLINK_LEASED: Duration = Duration::from_millis(100);
const POLL: Duration = Duration::from_millis(50);
const REPORT_EVERY: Duration = Duration::from_secs(5);

/// Clock cycles between two ring-oscillator samples. exp109's number, not
/// embassy-rp's — see where it is used.
const TRNG_SAMPLE_COUNT: u32 = 1000;


/// Set once the client has taken the address — the LED and the reporter both
/// read it, and neither of them owns the socket that sets it.
static LEASED: Signal<CriticalSectionRawMutex, ()> = Signal::new();

#[embassy_executor::task]
async fn usb_task(mut device: UsbDevice<'static, Driver<'static, USB>>) -> ! {
    device.run().await
}

#[embassy_executor::task]
async fn log_task(sender: Sender<'static, usb_reboot::UsbDriver>) -> ! {
    usb_log::run(sender).await
}

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

#[embassy_executor::task]
async fn ncm_task(runner: NcmRunner<'static, Driver<'static, USB>, MTU>) -> ! {
    runner.run().await
}

#[embassy_executor::task]
async fn net_task(mut runner: NetRunner<'static, Device<'static, MTU>>) -> ! {
    runner.run().await
}

/// The server. Everything it knows about DHCP it gets from the `dhcp` crate;
/// what lives here is the socket, the buffers, and the decision to broadcast.
#[embassy_executor::task]
async fn dhcp_task(stack: embassy_net::Stack<'static>) -> ! {
    // One datagram in flight each way is enough: DHCP is strictly
    // request-then-reply, and a client that sends two before reading one is not
    // a client this board is trying to serve.
    static RX_META: StaticCell<[PacketMetadata; 2]> = StaticCell::new();
    static TX_META: StaticCell<[PacketMetadata; 2]> = StaticCell::new();
    static RX_BUF: StaticCell<[u8; 1024]> = StaticCell::new();
    static TX_BUF: StaticCell<[u8; 1024]> = StaticCell::new();

    let mut socket = UdpSocket::new(
        stack,
        RX_META.init([PacketMetadata::EMPTY; 2]),
        RX_BUF.init([0; 1024]),
        TX_META.init([PacketMetadata::EMPTY; 2]),
        TX_BUF.init([0; 1024]),
    );

    // Bound to the port and *not* to an address. That is what makes the socket
    // accept a datagram sent to 255.255.255.255, which is the only address a
    // client that has no address of its own can send to.
    socket.bind(dhcp::SERVER_PORT).unwrap();
    log!("dhcp: listening on port {}", dhcp::SERVER_PORT);

    let broadcast = IpEndpoint::new(
        IpAddress::Ipv4(Ipv4Address::new(255, 255, 255, 255)),
        dhcp::CLIENT_PORT,
    );
    let lease = dhcp::Lease {
        client: CLIENT_IP,
        server: BOARD_IP,
        mask: MASK,
        seconds: LEASE_SECONDS,
    };

    let mut rx = [0u8; 1024];
    let mut tx = [0u8; dhcp::REPLY_LEN];

    loop {
        let (n, from) = match socket.recv_from(&mut rx).await {
            Ok(v) => v,
            Err(e) => {
                log!("dhcp: recv failed ({:?}) — carrying on", e);
                continue;
            }
        };

        let req = match dhcp::parse(&rx[..n]) {
            Ok(req) => req,
            Err(why) => {
                // Printed rather than dropped silently. A malformed packet on
                // port 67 is either a client this server does not understand or
                // something else entirely, and both are worth seeing once.
                log!("dhcp: {} bytes from {} refused: {:?}", n, from.endpoint, why);
                continue;
            }
        };

        let c = req.chaddr;
        let Some(reply) = dhcp::Reply::to(req.kind) else {
            log!(
                "dhcp: {:?} from {:02x}:{:02x}:{:02x}:{:02x}:{:02x}:{:02x} — nothing to say",
                req.kind, c[0], c[1], c[2], c[3], c[4], c[5]
            );
            continue;
        };

        log!(
            "dhcp: {:?} from {:02x}:{:02x}:{:02x}:{:02x}:{:02x}:{:02x}",
            req.kind, c[0], c[1], c[2], c[3], c[4], c[5]
        );

        let Some(len) = dhcp::build_reply(reply, &req, &lease, &mut tx) else {
            log!("dhcp: reply buffer too small — this is a bug, not a network problem");
            continue;
        };

        match socket.send_to(&tx[..len], broadcast).await {
            Ok(()) => {
                log!(
                    "dhcp: {:?} {}.{}.{}.{} broadcast, {} bytes",
                    reply, CLIENT_IP[0], CLIENT_IP[1], CLIENT_IP[2], CLIENT_IP[3], len
                );
                // An OFFER is a proposal; an ACK is the client having taken it.
                // Only the second one changes the LED, because only the second
                // one means the host agreed.
                if reply == dhcp::Reply::Ack {
                    LEASED.signal(());
                }
            }
            Err(e) => log!("dhcp: send failed ({:?})", e),
        }
    }
}

/// The desktop half of the readout, in words. Same three states as the LED.
#[embassy_executor::task]
async fn report_task(stack: embassy_net::Stack<'static>) -> ! {
    let started = Instant::now();
    let mut last: Option<(bool, bool)> = None;
    let mut next_idle = Instant::now() + REPORT_EVERY;

    loop {
        let now = (stack.is_link_up(), LEASED.signaled());
        if last != Some(now) || Instant::now() >= next_idle {
            let ms = (Instant::now() - started).as_millis();
            match now {
                (false, _) => log!("{} ms  link DOWN — nothing has claimed the NCM interface", ms),
                (true, false) => log!("{} ms  link UP, waiting for a DISCOVER", ms),
                (true, true) => log!(
                    "{} ms  link UP, {}.{}.{}.{} is leased out",
                    ms, CLIENT_IP[0], CLIENT_IP[1], CLIENT_IP[2], CLIENT_IP[3]
                ),
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
    config.product = Some("exp149 the board hands out the address");
    config.serial_number = Some("149");
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

    static NET_DEVICE_STATE: StaticCell<NetDeviceState<MTU, 4, 4>> = StaticCell::new();
    let (ncm_runner, device) =
        ncm.into_embassy_net_device::<MTU, 4, 4>(NET_DEVICE_STATE.init(NetDeviceState::new()), OUR_MAC);
    spawner.spawn(ncm_task(ncm_runner).unwrap());

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

    // Static, and this is the reversal exp148 was building towards. That
    // experiment refused a static address on principle — a board that assigns
    // itself one "has an address" on a host where nothing is listening, which
    // answers the question by fiat. Here the board is not asking a question. It
    // is the thing being asked, and a server without a fixed address is not a
    // server.
    //
    // `gateway: None` for the same reason there is no router option in the
    // reply: this board is one end of a cable.
    static RESOURCES: StaticCell<StackResources<3>> = StaticCell::new();
    let (stack, net_runner) = embassy_net::new(
        device,
        NetConfig::ipv4_static(StaticConfigV4 {
            address: Ipv4Cidr::new(
                Ipv4Address::new(BOARD_IP[0], BOARD_IP[1], BOARD_IP[2], BOARD_IP[3]),
                PREFIX,
            ),
            gateway: None,
            dns_servers: heapless_empty(),
        }),
        RESOURCES.init(StackResources::new()),
        u64::from_le_bytes(seed),
    );
    spawner.spawn(net_task(net_runner).unwrap());
    spawner.spawn(dhcp_task(stack).unwrap());
    spawner.spawn(report_task(stack).unwrap());

    log!("exp149 up. CDC-ACM for this log, CDC-NCM for the link.");
    log!(
        "  I am {}.{}.{}.{}/{} and I hand out {}.{}.{}.{}",
        BOARD_IP[0], BOARD_IP[1], BOARD_IP[2], BOARD_IP[3], PREFIX,
        CLIENT_IP[0], CLIENT_IP[1], CLIENT_IP[2], CLIENT_IP[3]
    );
    log!("  no router option, no DNS — this board routes nothing and says so.");
    log!("  LED: dark = no link, slow = nobody asked, fast = address taken.");

    loop {
        match (stack.is_link_up(), LEASED.signaled()) {
            (false, _) => {
                led.set_low();
                Timer::after(POLL).await;
            }
            (true, false) => blink(&mut led, BLINK_LINK).await,
            (true, true) => blink(&mut led, BLINK_LEASED).await,
        }
    }
}

/// `StaticConfigV4`'s DNS list is a `heapless::Vec` that this firmware has no
/// use for. Named rather than inlined so the empty case reads as a decision.
fn heapless_empty<const N: usize>() -> heapless::Vec<Ipv4Address, N> {
    heapless::Vec::new()
}

async fn blink(led: &mut Output<'static>, half: Duration) {
    led.set_high();
    Timer::after(half).await;
    led.set_low();
    Timer::after(half).await;
}
