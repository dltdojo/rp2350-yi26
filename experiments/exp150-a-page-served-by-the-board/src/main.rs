//! exp150 — a page served by the board.
//!
//! [exp149](../../exp149-the-board-hands-out-the-address/) got a phone to take
//! an address from the board. It also found something that makes this
//! experiment necessary rather than decorative: on a Pixel 9a the LED went
//! fast — the board sent an `ACK`, so Android really did run a DHCP client and
//! complete the handshake — and **Settings never showed an Ethernet network at
//! all**. Mobile data stayed up throughout.
//!
//! So Android took the address at a layer that never became a user-visible
//! network. Which leaves the question this experiment exists to answer:
//!
//! > **An address a browser cannot route to is not reachability.**
//!
//! A browser's sockets go to the phone's default network. Whether a literal
//! `http://192.168.7.1/` still leaves by the USB interface is a property of
//! Android's routing, not of this firmware, and there is exactly one way to
//! find out.
//!
//! # Why this is worth the trouble
//!
//! Everything in [`tools/pages/`](../../../tools/pages/) works by claiming a USB
//! interface from JavaScript, which means Chromium, a permission dialog, and a
//! device chooser with ghost entries in it. A board that serves its own page
//! needs none of that: any browser, no permission, no chooser, no install. That
//! is the prize, and it is why this road was worth walking.
//!
//! The cost is worth writing beside it. `http://` is **not a secure context**,
//! so the origin this board serves can never also use WebUSB. This road opens
//! one door by closing another.
//!
//! # Two builds, one round trip
//!
//! `--features announce-gateway` puts a router option in the DHCP offer: a
//! claim that this board is a way out to somewhere, which it is not. It is
//! built because a network with no gateway is one Android may correctly decline
//! to promote, and that would explain exp149 exactly.
//!
//! Both go in the same zip. [`docs/debugging-on-a-phone.md`](../../../docs/debugging-on-a-phone.md)
//! is emphatic that the round trip is the expensive thing; spending two of them
//! to learn one bit would be ignoring this repository's own notes.
//!
//! # What it serves, and what it does not
//!
//! A status page: link, lease, uptime, how many requests have been answered,
//! and the chip's own ID. Not the log — that would mean giving
//! [`usb-log`](../../../crates/usb-log/) a second consumer and a retained ring
//! buffer, which is a real feature and a real risk to the one instrument this
//! repository debugs with. The question in front of us is whether a browser can
//! reach the board at all, and this is the smallest thing that answers it.

#![no_std]
#![no_main]

use embassy_executor::Spawner;
use embassy_futures::select::{select, Either};
use embassy_net::tcp::TcpSocket;
#[cfg(not(feature = "ask-for-an-address"))]
use embassy_net::udp::{PacketMetadata, UdpSocket};
use embassy_net::{Config as NetConfig, Runner as NetRunner, StackResources};
#[cfg(not(feature = "ask-for-an-address"))]
use embassy_net::{IpAddress, IpEndpoint, Ipv4Address, Ipv4Cidr, StaticConfigV4};
use embassy_rp::bind_interrupts;
use embassy_rp::gpio::{Level, Output};
use embassy_rp::peripherals::{TRNG, USB};
use embassy_rp::rom_data;
use embassy_rp::trng::{Config as TrngConfig, InterruptHandler as TrngInterruptHandler, Trng};
use embassy_rp::usb::{Driver, InterruptHandler};
#[cfg(not(feature = "ask-for-an-address"))]
use embassy_sync::blocking_mutex::raw::CriticalSectionRawMutex;
#[cfg(not(feature = "ask-for-an-address"))]
use embassy_sync::signal::Signal;
use embedded_io_async::Write as _;
use core::fmt::Write as _;
use core::sync::atomic::{AtomicU32, Ordering};
use embassy_time::{with_timeout, Duration, Instant, Timer};
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

const HOST_MAC: [u8; 6] = [0x02, 0x26, 0x00, 0x00, 0x01, 0x50];
const OUR_MAC: [u8; 6] = [0x02, 0x26, 0x00, 0x00, 0x02, 0x50];

/// The whole network. `.1` is this board and `.2` is whatever is on the other
/// end of the cable — one address in the pool, because a USB link has one host
/// on it. `192.168.7.0/24` is private space that nothing else is likely to be
/// using at the same moment as a cable plugged into one board.
#[cfg(not(feature = "ask-for-an-address"))]
const BOARD_IP: [u8; 4] = [192, 168, 7, 1];
#[cfg(not(feature = "ask-for-an-address"))]
const CLIENT_IP: [u8; 4] = [192, 168, 7, 2];
#[cfg(not(feature = "ask-for-an-address"))]
const MASK: [u8; 4] = [255, 255, 255, 0];
#[cfg(not(feature = "ask-for-an-address"))]
const PREFIX: u8 = 24;

/// An hour. Long enough that nothing renews during an experiment, short enough
/// that a client which loses the board does not remember the address for a day.
#[cfg(not(feature = "ask-for-an-address"))]
const LEASE_SECONDS: u32 = 3600;

const HTTP_PORT: u16 = 80;

/// How long to wait for a closed connection's FIN to be acknowledged before
/// giving the worker back to the accept loop. A peer that has stopped answering
/// must not hold a worker; a peer that is answering takes milliseconds.
const CLOSE_TIMEOUT: Duration = Duration::from_secs(2);

/// `CHIP_INFO`, the first flag `get_sys_info` accepts — the same call
/// [exp139](../../exp139-a-table-of-one/) makes. Two of its words are the
/// chip's unique ID, and putting them on the page is what makes it *this*
/// board's page rather than a page.
const SYS_INFO_CHIP_INFO: u32 = 0x0001;

const BLINK_LINK: Duration = Duration::from_millis(500);
const BLINK_LEASED: Duration = Duration::from_millis(100);
const POLL: Duration = Duration::from_millis(50);
const REPORT_EVERY: Duration = Duration::from_secs(5);

/// Clock cycles between two ring-oscillator samples. exp109's number, not
/// embassy-rp's — see where it is used.
const TRNG_SAMPLE_COUNT: u32 = 1000;


/// Set once the client has taken the address — the LED and the reporter both
/// read it, and neither of them owns the socket that sets it. Only the server
/// role has anything to signal.
#[cfg(not(feature = "ask-for-an-address"))]
static LEASED: Signal<CriticalSectionRawMutex, ()> = Signal::new();

/// How many requests have been answered. The LED's fourth state is "this is
/// not zero", and the page prints the number, so a second reload is visibly a
/// second reload rather than a cached first one.
static SERVED: AtomicU32 = AtomicU32::new(0);

/// The two roles this firmware can take, and the whole of the difference
/// between them.
///
/// **Server** (default): a fixed address, because a server without one is not a
/// server. This is exp149's arrangement.
///
/// **Client** (`ask-for-an-address`): no address until somebody grants one. It
/// is the arrangement Android's Ethernet tethering requires — the phone is the
/// DHCP server and the router — and it is what Ubuntu's "shared to other
/// computers" does too, which is why it can be tested without a phone.
#[cfg(not(feature = "ask-for-an-address"))]
fn net_config() -> NetConfig {
    NetConfig::ipv4_static(StaticConfigV4 {
        address: Ipv4Cidr::new(
            Ipv4Address::new(BOARD_IP[0], BOARD_IP[1], BOARD_IP[2], BOARD_IP[3]),
            PREFIX,
        ),
        gateway: None,
        dns_servers: heapless_empty(),
    })
}

#[cfg(feature = "ask-for-an-address")]
fn net_config() -> NetConfig {
    NetConfig::dhcpv4(Default::default())
}

/// The address this board is actually on, whichever way it got there. `None`
/// while a client is still asking.
#[cfg(feature = "ask-for-an-address")]
fn my_address(stack: embassy_net::Stack<'_>) -> Option<[u8; 4]> {
    stack.config_v4().map(|c| c.address.address().octets())
}

#[cfg(not(feature = "ask-for-an-address"))]
fn my_address(_stack: embassy_net::Stack<'_>) -> Option<[u8; 4]> {
    Some(BOARD_IP)
}

/// Has this board got somewhere for a browser to reach it?
///
/// The two roles answer it from different places: a server has handed its
/// address *out* and waits for the client to take it; a client has been *given*
/// one. The LED reads this, so it means the same thing on both builds — "there
/// is now an address in play".
#[cfg(feature = "ask-for-an-address")]
fn addressed(stack: embassy_net::Stack<'_>) -> bool {
    stack.is_config_up()
}

#[cfg(not(feature = "ask-for-an-address"))]
fn addressed(_stack: embassy_net::Stack<'_>) -> bool {
    LEASED.signaled()
}

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
#[cfg(not(feature = "ask-for-an-address"))]
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
        // Six bytes, and the whole difference between the two builds this
        // experiment ships. See the feature's comment in Cargo.toml.
        router: if cfg!(feature = "announce-gateway") { Some(BOARD_IP) } else { None },
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

/// Reads the chip's own ID out of the ROM. Two words, and they are what makes
/// the served page identifiably *this* board — the same number
/// [exp146](../../exp146-a-page-that-writes-flash/) used to prove that the board
/// a page had written was the board that then booted.
fn chip_id() -> (u32, u32) {
    let mut buf = [0u32; 8];
    let n = unsafe { rom_data::get_sys_info(buf.as_mut_ptr(), buf.len(), SYS_INFO_CHIP_INFO) };
    if n >= 4 { (buf[3], buf[2]) } else { (0, 0) }
}

/// The page. Written into a fixed buffer with `core::fmt`, because a `no_std`
/// firmware has no `format!` and because a page whose size cannot grow without
/// bound is one that cannot run this board out of memory.
///
/// Deliberately plain HTML with no script and no external anything. It has to
/// render in whatever browser a person happens to be holding, including one
/// that never got WebUSB — that is the entire point of serving it from here.
fn render(out: &mut heapless::String<1024>, served: u32, addr: [u8; 4]) {
    let up = Instant::now().as_millis() / 1000;
    let (hi, lo) = chip_id();
    let _ = write!(
        out,
        "<!doctype html><meta charset=utf-8>\
<meta name=viewport content=\"width=device-width,initial-scale=1\">\
<title>exp150 &mdash; served by the board</title>\
<style>body{{font:16px/1.6 system-ui,sans-serif;margin:0 auto;max-width:34rem;padding:2rem 1rem}}\
h1{{font-size:1.3rem}}dt{{color:#888;font-size:.85rem}}dd{{margin:0 0 .8rem;font-family:ui-monospace,monospace}}</style>\
<h1>This page came off the board.</h1>\
<p>No WebUSB, no permission dialog, no chooser, no install. Your browser asked \
{}.{}.{}.{} for it over a USB cable.</p>\
<dl>\
<dt>chip id</dt><dd>{:#010x} {:#010x}</dd>\
<dt>requests answered</dt><dd>{}</dd>\
<dt>uptime</dt><dd>{} s</dd>\
<dt>gateway announced in DHCP</dt><dd>{}</dd>\
</dl>\
<p>Reload and watch the count go up &mdash; that is how you know this is the \
board answering and not a cache.</p>",
        addr[0], addr[1], addr[2], addr[3],
        hi, lo,
        served,
        up,
        if cfg!(feature = "announce-gateway") { "yes (this build lies)" } else { "no" },
    );
}

/// **Four of these run**, and the number was measured rather than chosen.
///
/// A browser opens several connections at once, speculatively, before it knows
/// whether it needs them — a page and its favicon is already two, and smoltcp
/// has no listen backlog, so a SYN that finds no listening socket is refused
/// rather than queued. With two workers, four simultaneous `curl`s got
/// `200 000 000 200`. Each worker costs about 3 KiB of buffers.
///
/// Buffers come from `main` rather than a `StaticCell` in here: `StaticCell`
/// panics on a second `init()`, so a pooled task that allocated its own would
/// bring the whole board down the moment the second worker started — a panic
/// before USB is ready, which is the one failure this firmware has no way back
/// from.
///
/// The request is **read and thrown away**. Not laziness — a deliberate
/// boundary. Parsing a request line means parsing untrusted input in a
/// firmware, and every path through this server returns the same page, so there
/// is nothing a path could select. exp151 is where a URL starts to mean
/// something, and that is where the parser belongs.
#[embassy_executor::task(pool_size = 4)]
async fn http_task(
    stack: embassy_net::Stack<'static>,
    rx: &'static mut [u8],
    tx: &'static mut [u8],
) -> ! {
    let mut discard = [0u8; 512];
    let mut body: heapless::String<1024> = heapless::String::new();
    let mut head: heapless::String<128> = heapless::String::new();

    loop {
        let mut socket = TcpSocket::new(stack, &mut rx[..], &mut tx[..]);
        // Without this a browser that opens a connection and says nothing —
        // which they do, speculatively — holds the only socket there is
        // forever, and the board looks dead to the next request.
        socket.set_timeout(Some(Duration::from_secs(10)));

        if let Err(e) = socket.accept(HTTP_PORT).await {
            log!("http: accept failed ({:?})", e);
            Timer::after(Duration::from_millis(200)).await;
            continue;
        }
        log!("http: connection from {:?}", socket.remote_endpoint());

        // Read whatever the client sends until it pauses. We need to consume
        // the request so the socket is not closed underneath an unsent one.
        match socket.read(&mut discard).await {
            Ok(0) | Err(_) => {
                socket.abort();
                continue;
            }
            Ok(n) => log!("http: {} bytes of request, discarded", n),
        }

        let served = SERVED.fetch_add(1, Ordering::Relaxed) + 1;
        body.clear();
        render(&mut body, served, my_address(stack).unwrap_or([0; 4]));
        head.clear();
        let _ = write!(
            head,
            "HTTP/1.0 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\
Content-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        );

        let ok = socket.write_all(head.as_bytes()).await.is_ok()
            && socket.write_all(body.as_bytes()).await.is_ok()
            && socket.flush().await.is_ok();
        if ok {
            log!("http: served request #{} ({} bytes)", served, body.len());
        } else {
            log!("http: request #{} was not delivered", served);
        }
        // `close()` only *starts* the shutdown — it sends a FIN. Dropping the
        // socket before that is acknowledged aborts the connection instead, and
        // a browser shown a reset after a 200 renders nothing at all.
        //
        // `flush()` is the wait that is actually wanted: it returns once the
        // send queue is empty and the FIN has left `FinWait1`/`LastAck` — our
        // data and our goodbye are both acknowledged. Whatever happens after
        // that is bookkeeping the peer does not need us for.
        //
        // The first version of this waited for `State::Closed` instead, and a
        // board measured the mistake. **A gracefully closed socket goes to
        // TIME-WAIT, not to `Closed`**, and sits there for about ten seconds —
        // so the loop always ran to its two-second deadline and cost this
        // worker two seconds of not listening. With two workers that meant
        // exactly two requests: `curl` in a loop got `200 200 000 000 000`.
        // Requests a second apart all passed, which is why a gap in the test
        // would have hidden it.
        socket.close();
        let _ = with_timeout(CLOSE_TIMEOUT, socket.flush()).await;
    }
}

/// The desktop half of the readout, in words. Same three states as the LED.
#[embassy_executor::task]
async fn report_task(stack: embassy_net::Stack<'static>) -> ! {
    let started = Instant::now();
    let mut last: Option<(bool, bool)> = None;
    let mut next_idle = Instant::now() + REPORT_EVERY;

    loop {
        let now = (stack.is_link_up(), addressed(stack));
        if last != Some(now) || Instant::now() >= next_idle {
            let ms = (Instant::now() - started).as_millis();
            match now {
                (false, _) => log!("{} ms  link DOWN — nothing has claimed the NCM interface", ms),
                // The two roles are waiting for opposite things here, and a
                // line that names the wrong one sends somebody looking in the
                // wrong place — which is the most expensive kind of wrong text
                // in this repository. See docs/debugging-on-a-phone.md.
                #[cfg(not(feature = "ask-for-an-address"))]
                (true, false) => log!("{} ms  link UP, waiting for a DISCOVER", ms),
                #[cfg(feature = "ask-for-an-address")]
                (true, false) => log!("{} ms  link UP, still asking for an address", ms),
                (true, true) => match my_address(stack) {
                    // The line somebody reads off `log.html` and types into a
                    // browser. It is printed on every idle tick, not once, so
                    // it cannot have scrolled away by the time anyone looks.
                    Some(a) => {
                        log!(
                            "{} ms  I am at http://{}.{}.{}.{}/ — {} request(s) served",
                            ms, a[0], a[1], a[2], a[3], SERVED.load(Ordering::Relaxed)
                        );
                        // Whether there is a way *out* — the question exp151
                        // asks, and the one thing about this link that a
                        // client role learns and a server role cannot.
                        #[cfg(feature = "ask-for-an-address")]
                        if let Some(g) = stack.config_v4().and_then(|c| c.gateway) {
                            let g = g.octets();
                            log!("        gateway {}.{}.{}.{} — there is a way out of here", g[0], g[1], g[2], g[3]);
                        }
                    }
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
    config.product = Some("exp150 a page served by the board");
    config.serial_number = Some("150");
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
    // One UDP socket for DHCP, four TCP sockets for the four HTTP workers, and
    // room to spare — running out here is a panic, not a refusal.
    static RESOURCES: StaticCell<StackResources<6>> = StaticCell::new();
    let (stack, net_runner) = embassy_net::new(
        device,
        net_config(),
        RESOURCES.init(StackResources::new()),
        u64::from_le_bytes(seed),
    );
    spawner.spawn(net_task(net_runner).unwrap());
    #[cfg(not(feature = "ask-for-an-address"))]
    spawner.spawn(dhcp_task(stack).unwrap());
    // One pair of buffers per worker, named separately so it is obvious there
    // are two of them and not one shared by accident.
    // One `StaticCell` per buffer and not a `StaticCell<[[u8; N]; 4]>`, because
    // `init()` panics the second time it is called and a loop over one cell is
    // exactly that mistake with extra steps.
    static RX: [StaticCell<[u8; 1024]>; 4] = [const { StaticCell::new() }; 4];
    static TX: [StaticCell<[u8; 2048]>; 4] = [const { StaticCell::new() }; 4];
    for (rx, tx) in RX.iter().zip(TX.iter()) {
        spawner.spawn(http_task(stack, rx.init([0; 1024]), tx.init([0; 2048])).unwrap());
    }
    spawner.spawn(report_task(stack).unwrap());

    log!("exp150 up. CDC-ACM for this log, CDC-NCM for the link.");

    #[cfg(not(feature = "ask-for-an-address"))]
    {
        log!(
            "  I am {}.{}.{}.{}/{} and I hand out {}.{}.{}.{}",
            BOARD_IP[0], BOARD_IP[1], BOARD_IP[2], BOARD_IP[3], PREFIX,
            CLIENT_IP[0], CLIENT_IP[1], CLIENT_IP[2], CLIENT_IP[3]
        );
        if cfg!(feature = "announce-gateway") {
            log!("  announcing myself as the gateway — this build LIES, on purpose.");
        } else {
            log!("  no router option, no DNS — this board routes nothing and says so.");
        }
        log!("  serving http://{}.{}.{}.{}/ on port {}",
            BOARD_IP[0], BOARD_IP[1], BOARD_IP[2], BOARD_IP[3], HTTP_PORT);
        log!("  LED: dark=no link, slow=nobody asked, fast=address taken, SOLID=page served.");
    }

    // The client role cannot print its address here: it does not have one yet,
    // and will not for a few hundred milliseconds. The reporter prints it once
    // it arrives, and keeps printing it — because the line somebody is going to
    // read off `log.html` and type into a browser must not have scrolled away
    // by the time they look.
    #[cfg(feature = "ask-for-an-address")]
    {
        log!("  asking for an address — whoever is on the other end is the server here.");
        log!("  serving HTTP on port {} at whatever address I am given.", HTTP_PORT);
        log!("  LED: dark=no link, slow=still asking, fast=I have an address, SOLID=page served.");
    }

    // Four states now, and the fourth is not a fourth *rate*. Three blink
    // speeds is already more than somebody can tell apart across a room, so
    // "a browser got the page" is **solid on** — the one reading that cannot
    // be confused with any of the others, for the result that matters most.
    loop {
        match (stack.is_link_up(), addressed(stack), SERVED.load(Ordering::Relaxed)) {
            (false, _, _) => {
                led.set_low();
                Timer::after(POLL).await;
            }
            (true, false, _) => blink(&mut led, BLINK_LINK).await,
            (true, true, 0) => blink(&mut led, BLINK_LEASED).await,
            (true, true, _) => {
                led.set_high();
                Timer::after(POLL).await;
            }
        }
    }
}

/// `StaticConfigV4`'s DNS list is a `heapless::Vec` that this firmware has no
/// use for. Named rather than inlined so the empty case reads as a decision.
#[cfg(not(feature = "ask-for-an-address"))]
fn heapless_empty<const N: usize>() -> heapless::Vec<Ipv4Address, N> {
    heapless::Vec::new()
}

async fn blink(led: &mut Output<'static>, half: Duration) {
    led.set_high();
    Timer::after(half).await;
    led.set_low();
    Timer::after(half).await;
}
