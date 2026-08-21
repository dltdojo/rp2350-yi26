//! exp155 — who else can knock.
//!
//! [exp161](../../exp161-one-port-four-doors/) put four doors on one port and
//! every one of them read something. This one adds a door that **changes the
//! board**, which is the first time in this repository that a network request
//! moves a pin — and the whole experiment is about what that costs, measured
//! rather than asserted.
//!
//! ```text
//!   GET|POST /led/<on|off|slow|fast|auto>          nothing is consulted
//!   POST     /control/led/<...>  + X-Yi26-Control  and an Origin that is mine
//!   OPTIONS  /control/led/<...>                    the question a browser asks first
//!   GET      /probe                                the same three knocks, from here
//! ```
//!
//! # The thing this was built to find out
//!
//! The obvious worry about serving control over HTTP is "can somebody else on
//! the network do this". The real answer is narrower and much more useful, and
//! it is about **the browser somebody is already running**, not about the
//! network:
//!
//! - A `GET` that changes something can be pulled by **any page**, from any
//!   origin, with an `<img>` tag. No CORS is involved: CORS was never about
//!   whether the request is *sent*, only about whether the reply may be *read*.
//! - A cross-site `POST` is no better. A form submission is a "simple" request
//!   and is not preflighted either.
//! - What a foreign page cannot do is send a request carrying a header nobody
//!   sends by accident, because that forces the browser to **ask first**, and
//!   asking is the one thing the board gets to answer.
//!
//! So the boundary is not the method and not the network. It is whether the
//! board is *asked before* anything happens. `/led/...` is the door with no
//! such question; `/control/led/...` is the door with one. Both are here on
//! purpose, and the README carries what a real Chrome did to each.
//!
//! # The LED, and why the handover waits for an address
//!
//! The LED is the instrument this whole road is read with on a phone
//! ([`docs/debugging-on-a-phone.md`](../../../docs/debugging-on-a-phone.md)),
//! and exp161 refused to spend it. This experiment spends it deliberately, and
//! only after the two states that carry information have stopped carrying it:
//! **dark = no link** and **slow = still asking** belong to the firmware until
//! there is an address, because until then they are the only thing anybody can
//! read. Once a browser can reach the board, being asked at all proves both.
//!
//! The consequence is stated rather than hidden: a page can set the LED to
//! something indistinguishable from a network state. That is what handing over
//! an instrument means.
//!
//! # What grew, and what did not
//!
//! [`http-route`](../../../crates/http-route/) gains exactly one capability —
//! find one named header — plus `OPTIONS` and the `/led/...` table. No bodies,
//! no `Content-Length`, no header table. exp161 named the gap it was leaving
//! (nothing about *who* is asking) and this is the smallest thing that closes
//! it.
//!
//! What did not grow: authentication, TLS, tokens, sessions. The guard here is
//! an origin check, and an origin check is only worth what the browser
//! enforcing it is worth — `curl` will send any `Origin` you like, and the
//! README says so plainly rather than letting a reader mistake this for
//! security against a program.

#![no_std]
#![no_main]

use embassy_executor::Spawner;
use embassy_futures::select::{select, Either};
use embassy_net::tcp::TcpSocket;
// Not gated on a role here: exp151 has only one, and the mDNS responder
// needs UDP whatever else is going on.
use embassy_net::udp::{PacketMetadata, UdpSocket};
use embassy_net::{
    Config as NetConfig, ConfigV4, Ipv4Address, Ipv4Cidr, Runner as NetRunner, StackResources,
    StaticConfigV4,
};
use embassy_rp::bind_interrupts;
use embassy_rp::gpio::{Level, Output};
use embassy_rp::peripherals::{TRNG, USB};
use embassy_rp::rom_data;
use embassy_rp::trng::{Config as TrngConfig, InterruptHandler as TrngInterruptHandler, Trng};
use embassy_rp::usb::{Driver, Endpoint, In, InterruptHandler, Out};
use embassy_usb::driver::{Endpoint as _, EndpointIn, EndpointOut};
use embassy_sync::blocking_mutex::raw::CriticalSectionRawMutex;
use embassy_sync::mutex::Mutex;
use embedded_io_async::Write as _;
use core::fmt::Write as _;
use core::sync::atomic::{AtomicBool, AtomicU32, AtomicU8, Ordering};
use embassy_time::{with_timeout, Duration, Instant, Timer};
use http_route::{Headers, Lamp, Method, Parsed, Refusal, Route};
use embassy_usb::class::cdc_acm::{CdcAcmClass, ControlChanged, Receiver, Sender, State as AcmState};
use embassy_usb::class::cdc_ncm::embassy_net::{Device, Runner as NcmRunner, State as NetDeviceState};
use embassy_usb::class::cdc_ncm::{CdcNcmClass, State as NcmState};
use embassy_usb::{Builder, Config as UsbConfig, UsbDevice};
use panic_halt as _;
use rp2350_linker as _;
use static_cell::StaticCell;
use usb_log::{log, log_transient};

/// The volume does not exist until this is true. Everything the host asks about
/// the medium is refused until then — see `storage_task`. exp152's mechanism,
/// unchanged: a drive that mounts before it knows the answer is a drive whose
/// file the host will serve out of its own cache.
static READY: AtomicBool = AtomicBool::new(false);

/// Set by `pin_task` once the address is settled, consumed by `storage_task`,
/// which is the only thing allowed to touch the disk bytes.
static PENDING_VOLUME: embassy_sync::blocking_mutex::Mutex<
    embassy_sync::blocking_mutex::raw::CriticalSectionRawMutex,
    core::cell::Cell<Option<[u8; 4]>>,
> = embassy_sync::blocking_mutex::Mutex::new(core::cell::Cell::new(None));

trait TakeAddr { fn take(&self) -> Option<[u8; 4]>; fn put(&self, a: [u8; 4]); }
impl TakeAddr for embassy_sync::blocking_mutex::Mutex<
    embassy_sync::blocking_mutex::raw::CriticalSectionRawMutex,
    core::cell::Cell<Option<[u8; 4]>>,
> {
    fn take(&self) -> Option<[u8; 4]> { self.lock(|c| c.take()) }
    fn put(&self, a: [u8; 4]) { self.lock(|c| c.set(Some(a))); }
}

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
    TRNG_IRQ => TrngInterruptHandler<TRNG>;
});

const PACKET: usize = 64;
const MTU: usize = 1514;

const HOST_MAC: [u8; 6] = [0x02, 0x26, 0x00, 0x00, 0x01, 0x55];
const OUR_MAC: [u8; 6] = [0x02, 0x26, 0x00, 0x00, 0x02, 0x55];

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



/// How many requests have been answered. The LED's fourth state is "this is
/// not zero", and the page prints the number, so a second reload is visibly a
/// second reload rather than a cached first one.
static SERVED: AtomicU32 = AtomicU32::new(0);

/// The same count, per door: index, log, status, trng, and everything refused.
///
/// One counter would have done for the LED. Five is what makes the concurrency
/// measurement readable afterwards — four clients asking four different things
/// at the same instant leave five numbers behind, and a single total cannot say
/// which of them arrived.
static COUNT_INDEX: AtomicU32 = AtomicU32::new(0);
static COUNT_LOG: AtomicU32 = AtomicU32::new(0);
static COUNT_STATUS: AtomicU32 = AtomicU32::new(0);
static COUNT_TRNG: AtomicU32 = AtomicU32::new(0);
static COUNT_REFUSED: AtomicU32 = AtomicU32::new(0);

/// The chip's one random number generator, behind one lock, for four workers.
///
/// **This is the experiment's second measurement and not an implementation
/// detail.** `/log` and `/status` read memory, so any number of them proceed
/// together; `/trng` needs the peripheral, and a peripheral is not a URL. A
/// second `/trng` arriving while the first is still sampling waits here, and
/// the wait is visible from the host as a response time that doubled — while a
/// `/log` issued at the same moment is unaffected.
///
/// `CriticalSectionRawMutex` and not `NoopRawMutex`: the workers are separate
/// tasks on one executor today, and a lock that is only correct because of that
/// is a lock that stops being correct the day somebody adds a second core.
static RNG: Mutex<CriticalSectionRawMutex, Option<Trng<'static, TRNG>>> = Mutex::new(None);

/// The most bytes `/trng` will produce for one request.
///
/// A time budget as much as a size one, and the two are not proportional.
/// [exp109](../../exp109-hardware-trng/) measured 5.6 ms for 8 bytes, which
/// would put 1 KiB near three quarters of a second. Measured here: **220 ms**,
/// so most of that 5.6 ms is the cost of *asking* rather than of the bytes —
/// 728 µs per byte in eights, 213 µs per byte in kilobytes.
///
/// Either way it is slow enough to notice from a browser, which is what makes
/// the shared peripheral visible at all.
const TRNG_MAX: usize = 1024;

/// What `/trng` produces when nobody said how much.
const TRNG_DEFAULT: usize = 32;

/// How many times a route changed the LED, and how many were turned away.
static COUNT_LED: AtomicU32 = AtomicU32::new(0);
static COUNT_CONTROL: AtomicU32 = AtomicU32::new(0);
static COUNT_TURNED_AWAY: AtomicU32 = AtomicU32::new(0);

/// What the LED has been told to be, or `LAMP_AUTO` for "go on reporting the
/// network".
///
/// A `u8` and not a `Mutex<Lamp>`: the LED loop reads this every 50 ms and a
/// request writes it, which is exactly what an atomic is for, and a lock held
/// across an `.await` in the blink loop would be a lock a request waits on.
static LAMP: AtomicU8 = AtomicU8::new(LAMP_AUTO);
const LAMP_AUTO: u8 = 0;

/// The header a request has to carry to reach the guarded door.
///
/// Its *name* is the whole mechanism and its value is not a secret — `1` is
/// fine. A header outside the handful CORS calls "simple" is one a browser will
/// not send without asking the server first, and being asked first is the only
/// thing on this board that a cross-origin page cannot route around.
const CONTROL_HEADER: &str = "X-Yi26-Control";

/// Which CORS answer a response carries. See where it is written out.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Cors {
    /// `*` — anyone may read this. The reading routes, as exp151 left them.
    Open,
    /// This one origin may read it. The guarded door, when it opened.
    Allowed,
    /// Nothing. A browser reads the absence as a refusal.
    Denied,
    /// The answer to a preflight: yes, and here is what you may then send.
    Preflight,
}

fn lamp_code(lamp: Lamp) -> u8 {
    match lamp {
        Lamp::Auto => LAMP_AUTO,
        Lamp::On => 1,
        Lamp::Off => 2,
        Lamp::Slow => 3,
        Lamp::Fast => 4,
    }
}

fn lamp_of(code: u8) -> Lamp {
    match code {
        1 => Lamp::On,
        2 => Lamp::Off,
        3 => Lamp::Slow,
        4 => Lamp::Fast,
        _ => Lamp::Auto,
    }
}

/// Returns whether this actually changed anything.
///
/// The distinction is not tidiness: a page that polls a control route would
/// otherwise write a retained log line every few seconds and bury the
/// measurement under its own footsteps — sixty-four lines is the whole ring.
fn set_lamp(lamp: Lamp) -> bool {
    LAMP.swap(lamp_code(lamp), Ordering::Relaxed) != lamp_code(lamp)
}

/// Is this `Origin` header this board's own?
///
/// Compared against the address the board is currently at, formatted the way a
/// browser formats an origin. Port 80 is never written out — `http://10.42.0.250`
/// and not `http://10.42.0.250:80` — which is a rule about origins, not a
/// simplification: a browser that sent the port would be sending a *different*
/// origin string, and this comparison would correctly refuse it.
///
/// `yi26.local` is accepted as well, because it is the same board by another
/// name and exp151 put that name on it.
fn same_origin(origin: Option<&str>, addr: [u8; 4]) -> bool {
    let Some(origin) = origin else { return true };
    let mut expected: heapless::String<40> = heapless::String::new();
    let _ = write!(expected, "http://{}.{}.{}.{}", addr[0], addr[1], addr[2], addr[3]);
    if origin == expected.as_str() {
        return true;
    }
    let mut by_name: heapless::String<40> = heapless::String::new();
    let _ = write!(by_name, "http://{}.local", MDNS_NAME_STR);
    origin == by_name.as_str()
}

/// How long a worker waits for the rest of a request line before giving up.
///
/// A client that opens a connection and sends half a line holds a worker until
/// this expires. Two seconds is long against a USB link's round trip and short
/// against a person's patience.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(2);

/// No address until somebody grants one.
///
/// exp149 and exp150 could be either — a server with a fixed address, or a
/// client asking for one — and exp150 measured that only the second is
/// reachable from a phone's browser. So there is one arrangement here and no
/// feature to choose it: the host is the DHCP server and the router, which is
/// what Android's Ethernet tethering does and what Ubuntu's "shared to other
/// computers" does.
fn net_config() -> NetConfig {
    let mut dhcp = embassy_net::DhcpConfig::default();
    // Option 12, the client's own name. A Linux host running dnsmasq turns this
    // into a resolvable name for free; whether Android's tethering DHCP server
    // does anything with it at all is the cheap half of this experiment — one
    // line, riding along with a test that was happening anyway.
    dhcp.hostname = Some(heapless::String::try_from(MDNS_NAME_STR).unwrap());
    NetConfig::dhcpv4(dhcp)
}

/// The host part this board moves to once it knows which network it is on.
///
/// **Why move at all.** The address a DHCP server picks is the server's
/// business, and a bookmark to it is only as durable as that decision. Pinning
/// makes the address a property of the *subnet* rather than of the lease, and
/// the subnet is the part Android keeps stable — measured across two sessions
/// on one phone, both `10.206.115.x`.
///
/// So the unknown shrinks from "an address" to "a network", and a bookmark made
/// once keeps working.
const PINNED_HOST: u8 = 250;

/// Put `host` into the network `addr`/`prefix` belongs to.
///
/// Written as mask arithmetic rather than "replace the last octet" because the
/// last octet is only the host part when the prefix is 24, and nothing
/// guarantees that. `None` when the result would be the network address or the
/// broadcast address, which are not usable and would take the board off the
/// air silently.
fn pin_into_subnet(addr: [u8; 4], prefix: u8, host: u8) -> Option<[u8; 4]> {
    if prefix >= 31 {
        return None; // no room for a host part worth choosing
    }
    let a = u32::from_be_bytes(addr);
    let mask = u32::MAX << (32 - prefix as u32);
    let pinned = (a & mask) | (host as u32 & !mask);
    if pinned == (a & mask) || pinned == (a & mask) | !mask {
        return None; // the network address, or the broadcast address
    }
    Some(pinned.to_be_bytes())
}

/// Waits for a lease, then stops being a DHCP client and takes a fixed address
/// on the same network.
///
/// Switching to a static config **removes the DHCP socket**, so nothing
/// afterwards overwrites this. That is a property of `embassy-net` worth
/// knowing before relying on it, and it was read out of the source rather than
/// hoped for.
#[embassy_executor::task]
async fn pin_task(stack: embassy_net::Stack<'static>) -> ! {
    stack.wait_config_up().await;
    let Some(cfg) = stack.config_v4() else {
        core::future::pending::<()>().await;
        unreachable!()
    };
    let got = cfg.address.address().octets();
    let prefix = cfg.address.prefix_len();

    match pin_into_subnet(got, prefix, PINNED_HOST) {
        Some(pinned) => {
            log!(
                "pinning: was given {}.{}.{}.{}/{}, taking {}.{}.{}.{} instead",
                got[0], got[1], got[2], got[3], prefix,
                pinned[0], pinned[1], pinned[2], pinned[3]
            );
            log!("  the subnet is the stable part; the lease is not. Bookmark the new one.");
            stack.set_config_v4(ConfigV4::Static(StaticConfigV4 {
                address: Ipv4Cidr::new(
                    Ipv4Address::new(pinned[0], pinned[1], pinned[2], pinned[3]),
                    prefix,
                ),
                gateway: cfg.gateway,
                dns_servers: cfg.dns_servers,
            }));
        }
        None => log!(
            "pinning: /{} leaves no room for host {} — keeping the leased address",
            prefix, PINNED_HOST
        ),
    }
    // Whatever address won, the drive is laid down with *that* one. Reading it
    // back out of the stack rather than reusing `pinned` is what makes the two
    // agree even when the pinning was declined.
    if let Some(addr) = my_address(stack) {
        PENDING_VOLUME.put(addr);
    }
    core::future::pending::<()>().await;
    unreachable!()
}

/// The address this board was given. `None` until somebody gives it one, which
/// is most of the first ten seconds.
fn my_address(stack: embassy_net::Stack<'_>) -> Option<[u8; 4]> {
    stack.config_v4().map(|c| c.address.address().octets())
}


/// Has this board got somewhere a browser could reach it? The LED reads this.
fn addressed(stack: embassy_net::Stack<'_>) -> bool {
    stack.is_config_up()
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

/// Reads the chip's own ID out of the ROM — the same call
/// [exp139](../../exp139-a-table-of-one/) makes. It goes on the page so that
/// what a browser is looking at is identifiably *this* board.
fn chip_id() -> (u32, u32) {
    let mut buf = [0u32; 8];
    let n = unsafe { rom_data::get_sys_info(buf.as_mut_ptr(), buf.len(), SYS_INFO_CHIP_INFO) };
    if n >= 4 { (buf[3], buf[2]) } else { (0, 0) }
}

/// The style and the nav strip every HTML page here shares.
///
/// One string and not three copies: the doors are supposed to look like doors
/// into the same board, and three copies of a stylesheet drift apart the first
/// time one of them is edited.
const CHROME: &str = "<meta charset=utf-8>\
<meta name=viewport content=\"width=device-width,initial-scale=1\">\
<style>body{font:14px/1.5 ui-monospace,monospace;margin:0;padding:1rem;background:#111;color:#ddd}\
h1{font:600 15px/1.4 system-ui,sans-serif;margin:0 0 .3rem}\
p{font:12px/1.5 system-ui,sans-serif;color:#888;margin:0 0 1rem}\
nav{font:12px/1.5 system-ui,sans-serif;margin:0 0 1rem}\
nav a{color:#6cf;margin-right:1rem}\
pre{white-space:pre-wrap;word-break:break-all;margin:0}\
td{padding:0 1rem .2rem 0}</style>\
<nav><a href=\"/\">/</a><a href=\"/log\">/log</a><a href=\"/status\">/status</a>\
<a href=\"/trng\">/trng</a></nav>";

/// `/` — what is on this board, and how to reach the rest of it.
///
/// The index exists because a person who has just typed an address has no way
/// to guess `/trng`, and because the counters make the point the README makes
/// in words: four doors, one port, and the numbers move independently.
fn render_index(out: &mut [u8], addr: [u8; 4]) -> usize {
    let mut w = Cursor { buf: out, n: 0 };
    let (hi, lo) = chip_id();
    let up = Instant::now().as_millis() / 1000;
    let _ = write!(
        w,
        "<!doctype html>{CHROME}\
<title>{}.{}.{}.{} &mdash; the board</title>\
<h1>{}.{}.{}.{} &mdash; chip {:#010x} {:#010x}</h1>\
<p>up {} s. One USB cable, one TCP port, four paths. Nothing here is installed on \
your machine and nothing claimed a device: this is HTTP.</p>\
<table>\
<tr><td><a href=\"/log\">/log</a></td><td>the firmware's own log, refreshing itself</td><td>{}</td></tr>\
<tr><td><a href=\"/status\">/status</a></td><td>the same facts as JSON</td><td>{}</td></tr>\
<tr><td><a href=\"/trng\">/trng</a></td><td>hardware random bytes &mdash; <code>?n=64</code>, up to {}</td><td>{}</td></tr>\
<tr><td>/</td><td>this page</td><td>{}</td></tr>\
<tr><td>refused</td><td>parsed and not acted on</td><td>{}</td></tr>\
</table>\
<p>The count beside each path is how many times it has been asked for. \
They move independently, which is the whole point.</p>\
<h1>the LED, from here</h1>\
<p>The LED is <b>{}</b>. These are ordinary links &mdash; no script, no form, \
nothing but a URL, which is exactly what makes them worth measuring. \
<b>Any page that can route to this board can pull the same four.</b></p>\
<nav><a href=\"/led/on\">on</a><a href=\"/led/off\">off</a>\
<a href=\"/led/slow\">slow</a><a href=\"/led/fast\">fast</a>\
<a href=\"/led/auto\">give it back</a></nav>\
<p>&ldquo;Give it back&rdquo; returns the LED to reporting the network, which is \
what it does before anybody asks and whenever there is no address. \
<a href=\"/probe\">/probe</a> knocks on all three doors from this origin; \
serve the same page from anywhere else and only the origin differs.</p>",
        addr[0], addr[1], addr[2], addr[3],
        addr[0], addr[1], addr[2], addr[3], hi, lo, up,
        COUNT_LOG.load(Ordering::Relaxed),
        COUNT_STATUS.load(Ordering::Relaxed),
        TRNG_MAX,
        COUNT_TRNG.load(Ordering::Relaxed),
        COUNT_INDEX.load(Ordering::Relaxed),
        COUNT_REFUSED.load(Ordering::Relaxed),
        lamp_of(LAMP.load(Ordering::Relaxed)).word(),
    );
    w.n
}

/// `/status` — the same facts, for something that is not a person.
///
/// JSON and not HTML because the caller here is `curl` in a check script or a
/// page fetching in the background, and a scraper of `<td>`s is a test that
/// breaks when somebody improves the styling.
///
/// `lost` is in here deliberately: a client that polls this can tell that the
/// ring dropped lines between two polls, which reading `/log` alone cannot.
fn render_status(out: &mut [u8], addr: [u8; 4], gateway: Option<[u8; 4]>, link: bool) -> usize {
    let mut w = Cursor { buf: out, n: 0 };
    let (hi, lo) = chip_id();
    let _ = write!(
        w,
        "{{\"chip\":\"{:08x}{:08x}\",\"up_ms\":{},\"link\":{},\
\"address\":\"{}.{}.{}.{}\",",
        hi, lo,
        Instant::now().as_millis(),
        link,
        addr[0], addr[1], addr[2], addr[3],
    );
    match gateway {
        Some(g) => { let _ = write!(w, "\"gateway\":\"{}.{}.{}.{}\",", g[0], g[1], g[2], g[3]); }
        None => { let _ = write!(w, "\"gateway\":null,"); }
    }
    // The LED's state, and how it got there. This is the field the whole
    // experiment is read from: a browser is the subject, `/status` is the
    // instrument, and nobody has to be looking at the board.
    let _ = write!(
        w,
        "\"led\":\"{}\",\"led_is_auto\":{},",
        lamp_of(LAMP.load(Ordering::Relaxed)).word(),
        LAMP.load(Ordering::Relaxed) == LAMP_AUTO,
    );
    let _ = write!(
        w,
        "\"served\":{{\"index\":{},\"log\":{},\"status\":{},\"trng\":{},\
\"led\":{},\"control\":{},\"turned_away\":{},\"refused\":{}}},\
\"log_lines_lost\":{}}}",
        COUNT_INDEX.load(Ordering::Relaxed),
        COUNT_LOG.load(Ordering::Relaxed),
        COUNT_STATUS.load(Ordering::Relaxed),
        COUNT_TRNG.load(Ordering::Relaxed),
        COUNT_LED.load(Ordering::Relaxed),
        COUNT_CONTROL.load(Ordering::Relaxed),
        COUNT_TURNED_AWAY.load(Ordering::Relaxed),
        COUNT_REFUSED.load(Ordering::Relaxed),
        // `usb-log` has no "how many were lost" call of its own — the count
        // comes back from the walk. Walking with an empty closure is the whole
        // cost, and it is bounded by the ring's line count rather than by how
        // long the board has been up.
        usb_log::retained(|_| {}),
    );
    w.n
}

/// How many bytes `?n=` asked for, clamped, with anything unreadable treated as
/// "not said".
///
/// No error for a bad number, and that is a decision rather than laziness: this
/// is a query string, not a path, and the only thing a caller can do with
/// `?n=abc` is to have meant something. The response says how many bytes it
/// contains, so a caller that cared can check.
fn wanted_bytes(query: Option<&str>) -> usize {
    let Some(q) = query else { return TRNG_DEFAULT };
    let mut n: Option<usize> = None;
    for field in q.split('&') {
        if let Some(v) = field.strip_prefix("n=") {
            n = v.parse::<usize>().ok();
        }
    }
    n.unwrap_or(TRNG_DEFAULT).clamp(1, TRNG_MAX)
}

/// `/trng` — the bytes, as hex, with what they cost printed beside them.
///
/// Plain text and not HTML: this is the one route whose output somebody might
/// actually pipe somewhere, and `<pre>` in the middle of it would be a small
/// cruelty. The elapsed time is part of the body because it is the number this
/// experiment is about — ask for two of these at once and watch the second one
/// pay for the first.
///
/// # Narrow, because a phone measured it
///
/// Everything here is inside **32 columns**, and that is not a style
/// preference. A phone rendered the first version with one long header line and
/// 32 bytes of hex per line, and Chrome does not wrap `text/plain`: the line
/// ran off the right edge and the reader saw `waiting for the one TRNG took`
/// with the number missing. A `text/plain` body has no stylesheet to fix that
/// afterwards, so the wrapping has to be in the bytes.
///
/// The two costs are on their own lines for the same reason, and it improves
/// the desktop reading too — they are two different facts.
fn render_trng(out: &mut [u8], bytes: &[u8], took_us: u64, waited_us: u64) -> usize {
    let mut w = Cursor { buf: out, n: 0 };
    let _ = write!(
        w,
        "{} bytes from the RP2350 TRNG\n\
sampling: {} us\n\
waiting for the one TRNG: {} us\n\n",
        bytes.len(), took_us, waited_us
    );
    for (i, b) in bytes.iter().enumerate() {
        let _ = write!(w, "{:02x}", b);
        w.byte(if (i + 1) % 8 == 0 { b'\n' } else { b' ' });
    }
    w.byte(b'\n');
    w.n
}

/// The answer to a request that asked the LED to be something.
///
/// Plain text, and it names the state rather than saying "ok": a caller that
/// polls this can tell what the board thinks the LED is without a second
/// request, and a person watching a real LED can compare the two.
fn render_lamp(out: &mut [u8], lamp: Lamp, done: bool, why: &str) -> usize {
    let mut w = Cursor { buf: out, n: 0 };
    if done {
        let _ = write!(w, "led: {}\n", lamp.word());
    } else {
        let _ = write!(w, "led: unchanged, still {}\nrefused: {}\n",
                       lamp_of(LAMP.load(Ordering::Relaxed)).word(), why);
    }
    w.n
}

/// `/probe` — the page that knocks on all three doors, from the board's own
/// origin.
///
/// **This is the only page in this repository with a script in it, and it is
/// not a page for a phone.** It is a test instrument: the same four attempts,
/// run from an origin that is this board's own. Serve the identical file from
/// anywhere else and the only thing that differs is the origin — which is the
/// whole experiment, and the reason it is written as one page rather than two.
///
/// What it reports on screen is a convenience. **The measurement is read from
/// `/status` and from the log**, because the question is what reached the
/// board, and a page cannot be a witness to that — it can only say what its own
/// browser told it. `AGENTS.md` has the general form of that rule.
fn render_probe(out: &mut [u8], addr: [u8; 4]) -> usize {
    let mut w = Cursor { buf: out, n: 0 };
    let _ = write!(
        w,
        "<!doctype html>{CHROME}<title>probe</title>\
<h1>knocking on three doors</h1>\
<p>Base: <code>http://{}.{}.{}.{}</code>. Read the real answer from \
<a href=\"/status\">/status</a> and <a href=\"/log\">/log</a>, not from this page.</p>\
<pre id=out>starting…\n</pre>\
<iframe name=sink style=\"display:none\"></iframe>\
<form id=f method=post target=sink action=\"http://{}.{}.{}.{}/led/slow\"></form>\
<script>\
const B='http://{}.{}.{}.{}';\
const o=document.getElementById('out');\
const say=(s)=>{{o.textContent+=s+'\\n';}};\
const img=new Image();\
img.onerror=()=>say('1 <img src=/led/fast>: request left the browser (the reply is not an image, which is fine)');\
img.onload=()=>say('1 <img src=/led/fast>: loaded');\
img.src=B+'/led/fast';\
setTimeout(()=>{{document.getElementById('f').submit();say('2 cross-site form POST /led/slow: submitted');}},600);\
setTimeout(()=>{{\
fetch(B+'/control/led/off',{{method:'POST',headers:{{'{}':'1'}}}})\
.then(r=>say('3 fetch POST /control/led/off: HTTP '+r.status))\
.catch(e=>say('3 fetch POST /control/led/off: blocked before it was answered — '+e));\
}},1200);\
</script>",
        addr[0], addr[1], addr[2], addr[3],
        addr[0], addr[1], addr[2], addr[3],
        addr[0], addr[1], addr[2], addr[3],
        CONTROL_HEADER
    );
    w.n
}

/// The body of a refusal or a 404, in the same words the log used.
fn render_error(out: &mut [u8], status: u16, why: &str) -> usize {
    let mut w = Cursor { buf: out, n: 0 };
    let _ = write!(w, "{} — {}\n\nThis board serves / /log /status /trng and nothing else.\n", status, why);
    w.n
}

/// `/log` — the retained log, and a `<meta refresh>` so it updates itself.
///
/// No script, deliberately. This page exists for browsers that do not have
/// WebUSB, and assuming they have anything else would be repeating the
/// mistake one layer up. A meta refresh is 1996 technology and it works
/// everywhere, including in a browser with JavaScript turned off.
///
/// Written into a caller-owned buffer rather than a `String`, because the log
/// is up to `RETAIN_LINES` lines long and a response whose size depends on how
/// long the board has been running is one that eventually will not fit.
fn render(out: &mut [u8], addr: [u8; 4]) -> usize {
    let mut w = Cursor { buf: out, n: 0 };
    let (hi, lo) = chip_id();
    let up = Instant::now().as_millis() / 1000;

    let _ = write!(
        w,
        "<!doctype html><meta http-equiv=refresh content=3>{CHROME}\
<title>{}.{}.{}.{} &mdash; the board's log</title>\
<h1>{}.{}.{}.{} &mdash; chip {:#010x} {:#010x}</h1>\
<p>up {} s, {} request(s) answered. This page refreshes itself every 3 s. No WebUSB, no permission \
dialog, no toolchain &mdash; any browser that can open an address can read \
this board's log.</p><pre>",
        addr[0], addr[1], addr[2], addr[3],
        addr[0], addr[1], addr[2], addr[3], hi, lo, up,
        SERVED.load(Ordering::Relaxed)
    );

    // Everything below runs inside a critical section, so it must be short and
    // must not log — logging from inside the lock that logging takes is the
    // shortest deadlock in the book.
    let lost = usb_log::retained(|line| {
        // Escaped, because the log is text this firmware formatted and a
        // reader who logs a `<` should see a `<`. Three characters is the
        // whole of HTML escaping that matters inside a <pre>.
        for &b in line {
            match b {
                b'<' => { let _ = w.write_str("&lt;"); }
                b'>' => { let _ = w.write_str("&gt;"); }
                b'&' => { let _ = w.write_str("&amp;"); }
                _ => w.byte(b),
            }
        }
        w.byte(b'\n');
    });

    let _ = write!(w, "</pre>");
    if lost > 0 {
        // Said rather than hidden. A reader shown a log with its beginning
        // quietly missing draws conclusions from something that is not there.
        let _ = write!(w, "<p>{} earlier line(s) scrolled out of the ring.</p>", lost);
    }
    w.n
}

/// The name this board answers to. `<this>.local`, and nothing else — no
/// subdomains, because a board is one thing and not a zone.
const MDNS_NAME: &[u8] = MDNS_NAME_STR.as_bytes();
const MDNS_NAME_STR: &str = "yi26";

/// How long a resolver may believe the answer. Two minutes: long enough that a
/// page reloading every three seconds does not ask again each time, short
/// enough that a board unplugged and replugged onto a different address is not
/// remembered wrongly for an afternoon.
const MDNS_TTL: u32 = 120;

/// Answers `yi26.local` for as long as this board has an address to give.
///
/// Android resolves `.local` by sending an ordinary DNS query to
/// 224.0.0.251:5353 and waiting for a reply — RFC 6762 §5.1, one-shot
/// multicast DNS. So the whole responder is: receive, check it is a question
/// for us, reply to whoever asked. The protocol lives in
/// [`mdns`](../../../crates/mdns/), which has no socket in it.
///
/// The reply goes **unicast, back to the sender**, rather than to the
/// multicast group. That is what a one-shot querier is waiting for, and on a
/// link with one host there is nobody else the answer would be for.
#[embassy_executor::task]
async fn mdns_task(stack: embassy_net::Stack<'static>) -> ! {
    static RX_META: StaticCell<[PacketMetadata; 4]> = StaticCell::new();
    static TX_META: StaticCell<[PacketMetadata; 4]> = StaticCell::new();
    static RX_BUF: StaticCell<[u8; 1024]> = StaticCell::new();
    static TX_BUF: StaticCell<[u8; 512]> = StaticCell::new();

    // Nothing can be received until the group is joined, and the group cannot
    // be joined until the interface has an address. Waiting here rather than
    // retrying blindly keeps the failure legible.
    stack.wait_config_up().await;
    match stack.join_multicast_group(embassy_net::Ipv4Address::new(
        mdns::MULTICAST[0], mdns::MULTICAST[1], mdns::MULTICAST[2], mdns::MULTICAST[3],
    )) {
        Ok(()) => log!("mdns: listening as {}.local", core::str::from_utf8(MDNS_NAME).unwrap_or("?")),
        Err(e) => {
            log!("mdns: could not join the multicast group ({:?}) — no name for this board", e);
            core::future::pending::<()>().await;
            unreachable!()
        }
    }

    let mut socket = UdpSocket::new(
        stack,
        RX_META.init([PacketMetadata::EMPTY; 4]),
        RX_BUF.init([0; 1024]),
        TX_META.init([PacketMetadata::EMPTY; 4]),
        TX_BUF.init([0; 512]),
    );
    if let Err(e) = socket.bind(mdns::PORT) {
        log!("mdns: cannot bind port {} ({:?})", mdns::PORT, e);
        core::future::pending::<()>().await;
    }

    let mut rx = [0u8; 1024];
    let mut tx = [0u8; mdns::REPLY_LEN];
    loop {
        let Ok((n, from)) = socket.recv_from(&mut rx).await else { continue };
        let Some(addr) = my_address(stack) else { continue };

        match mdns::question_for(&rx[..n], MDNS_NAME) {
            Ok(q) => {
                let Some(len) = mdns::answer(&rx[..n], &q, addr, MDNS_TTL, &mut tx) else {
                    log!("mdns: reply buffer too small — a bug, not a network problem");
                    continue;
                };
                match socket.send_to(&tx[..len], from.endpoint).await {
                    Ok(()) => log_transient!(
                        "mdns: answered {}.local -> {}.{}.{}.{}",
                        core::str::from_utf8(MDNS_NAME).unwrap_or("?"),
                        addr[0], addr[1], addr[2], addr[3]
                    ),
                    Err(e) => log_transient!("mdns: reply failed ({:?})", e),
                }
            }
            // Left at transient too: a link with any traffic on it carries
            // questions about other names, and a log full of "not mine" is a
            // log with the interesting part pushed out of it.
            Err(why) => log_transient!("mdns: {} bytes ignored: {:?}", n, why),
        }
    }
}

/// A `core::fmt::Write` over a plain byte slice that truncates instead of
/// failing. Same bargain `usb-log`'s `Line` makes, and for the same reason: a
/// page that can fail to render is a page whose caller has to handle that, and
/// the handling is always worse than a short page.
struct Cursor<'a> {
    buf: &'a mut [u8],
    n: usize,
}

impl Cursor<'_> {
    fn byte(&mut self, b: u8) {
        if self.n < self.buf.len() {
            self.buf[self.n] = b;
            self.n += 1;
        }
    }
}

impl core::fmt::Write for Cursor<'_> {
    fn write_str(&mut self, s: &str) -> core::fmt::Result {
        for &b in s.as_bytes() {
            self.byte(b);
        }
        Ok(())
    }
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
/// The request is **read until its first line is whole**, which is the change
/// this experiment is. exp150 read once and threw the bytes away, and could,
/// because every path returned the same page. Here a path selects something, so
/// a request that arrives in two segments has to be waited for rather than
/// guessed at — [`http_route::parse`] returns [`Parsed::Incomplete`] until the
/// line is complete, and this loop is what that return value is for.
#[embassy_executor::task(pool_size = 4)]
async fn http_task(
    stack: embassy_net::Stack<'static>,
    rx: &'static mut [u8],
    tx: &'static mut [u8],
    page: &'static mut [u8],
) -> ! {
    // Bigger than exp161's 512, because this experiment reads headers and a
    // browser sends four to six hundred bytes of them. Still small enough that
    // filling it is itself an answer.
    let mut req = [0u8; 1536];
    let mut head: heapless::String<384> = heapless::String::new();
    let mut origin_seen: heapless::String<48> = heapless::String::new();

    loop {
        let mut socket = TcpSocket::new(stack, &mut rx[..], &mut tx[..]);
        // Without this a browser that opens a connection and says nothing —
        // which they do, speculatively — holds the only socket there is
        // forever, and the board looks dead to the next request.
        socket.set_timeout(Some(Duration::from_secs(10)));

        if let Err(e) = socket.accept(HTTP_PORT).await {
            log_transient!("http: accept failed ({:?})", e);
            Timer::after(Duration::from_millis(200)).await;
            continue;
        }
        log_transient!("http: connection from {:?}", socket.remote_endpoint());

        // Read until the request line **and its headers** are whole, the buffer
        // is full, or the peer stops talking.
        //
        // exp161 stopped at the line. This one cannot: the difference between
        // "the page I served asked" and "some other page asked" is a header, so
        // a request whose header block has not arrived is not a request yet.
        // Getting that wrong in the other direction is the expensive mistake —
        // reading "no Origin" out of a block that had simply not arrived would
        // let a cross-origin write through on a slow link, and it would do so
        // *sometimes*, which is the worst kind of bug to be handed.
        //
        // `have` is the only state this loop carries; the request is re-parsed
        // once afterwards, so the borrow of `req` never outlives the reads
        // into it.
        let mut have = 0usize;
        let mut gone = false;
        let decided: Option<Result<usize, Refusal>> = loop {
            match http_route::parse(&req[..have]) {
                // A line that will never be acceptable is refused now. Waiting
                // for the headers of a request that is already malformed only
                // holds a worker open for whoever sent it.
                Parsed::Refused(why) => break Some(Err(why)),
                Parsed::Complete(r) => match http_route::headers(&req[..have], r.line_len) {
                    Headers::Complete(_) => break Some(Ok(r.line_len)),
                    Headers::TooLong => break Some(Err(Refusal::LineTooLong)),
                    Headers::Incomplete => {}
                },
                Parsed::Incomplete => {}
            }
            if have == req.len() {
                break Some(Err(Refusal::LineTooLong));
            }
            match with_timeout(REQUEST_TIMEOUT, socket.read(&mut req[have..])).await {
                Ok(Ok(0)) | Ok(Err(_)) => { gone = true; break None }
                Err(_) => {
                    log_transient!("http: no whole request within {} s", REQUEST_TIMEOUT.as_secs());
                    gone = true;
                    break None;
                }
                Ok(Ok(n)) => have += n,
            }
        };
        let Some(decided) = decided else {
            let _ = gone;
            socket.abort();
            continue;
        };

        let served = SERVED.fetch_add(1, Ordering::Relaxed) + 1;
        let addr = my_address(stack).unwrap_or([0; 4]);
        origin_seen.clear();

        // One place where a path becomes an answer. Everything above this is
        // transport and everything below it is bytes; this match is the
        // experiment.
        let (status, ctype, len, cors) = match decided {
            Err(why) => {
                COUNT_REFUSED.fetch_add(1, Ordering::Relaxed);
                // The reason is logged and also sent. On a phone the log is
                // three taps away and the response body is on the screen.
                log_transient!("http: {} — {}", why.status(), why.reason());
                (why.status(), "text/plain; charset=utf-8",
                 render_error(page, why.status(), why.reason()), Cors::Open)
            }
            // Cannot happen — the loop above leaves only when both of these are
            // there — and it answers rather than panicking, because a panic
            // here is a board that stops enumerating and needs a hand on
            // BOOTSEL. An `unreachable!()` in a firmware is a bet, not an
            // assertion.
            Ok(line_len)
                if !matches!(http_route::parse(&req[..have]), Parsed::Complete(_))
                    || !matches!(http_route::headers(&req[..have], line_len), Headers::Complete(_)) =>
            {
                COUNT_REFUSED.fetch_add(1, Ordering::Relaxed);
                log!("http: a decided request would not re-parse — a bug, not a client");
                let len = render_error(page, 400, "could not re-read the request");
                (400, "text/plain; charset=utf-8", len, Cors::Open)
            }
            Ok(line_len) => {
                let (r, h) = match (
                    http_route::parse(&req[..have]),
                    http_route::headers(&req[..have], line_len),
                ) {
                    (Parsed::Complete(r), Headers::Complete(h)) => (r, h),
                    // Excluded by the guard above; the compiler cannot know it.
                    _ => continue,
                };

                // Who is asking. Recorded for every request, acted on for one
                // kind — which is the whole shape of this experiment.
                let origin = h.get("Origin");
                if let Some(o) = origin {
                    // Truncated **here**, visibly, rather than by the log line.
                    //
                    // `usb-log` cuts a whole line at 96 bytes, timestamp
                    // included, and says nothing about it. A security log whose
                    // record of *who asked* silently loses its tail is worse
                    // than one that says it lost it — the phone that read
                    // exp153's `http://10` learned this one layer down. So a
                    // long origin is cut where it can be marked.
                    let fits = o.len().min(origin_seen.capacity() - 1);
                    let cut = o.is_char_boundary(fits);
                    let _ = origin_seen.push_str(if cut { &o[..fits] } else { o.split_at(fits).0 });
                    if o.len() > fits {
                        let _ = origin_seen.push('~');
                    }
                }
                let ours = origin.is_none() || same_origin(origin, addr);

                match (r.method, r.route) {
                    (Method::Get, Route::Index) => {
                        COUNT_INDEX.fetch_add(1, Ordering::Relaxed);
                        (200, "text/html; charset=utf-8", render_index(page, addr), Cors::Open)
                    }
                    (Method::Get, Route::Log) => {
                        COUNT_LOG.fetch_add(1, Ordering::Relaxed);
                        (200, "text/html; charset=utf-8", render(page, addr), Cors::Open)
                    }
                    (Method::Get, Route::Probe) => {
                        COUNT_INDEX.fetch_add(1, Ordering::Relaxed);
                        (200, "text/html; charset=utf-8", render_probe(page, addr), Cors::Open)
                    }
                    (Method::Get, Route::Status) => {
                        COUNT_STATUS.fetch_add(1, Ordering::Relaxed);
                        let cfg = stack.config_v4();
                        let len = render_status(
                            page,
                            addr,
                            cfg.and_then(|c| c.gateway).map(|g| g.octets()),
                            stack.is_link_up(),
                        );
                        (200, "application/json", len, Cors::Open)
                    }
                    (Method::Get, Route::Trng) => {
                        COUNT_TRNG.fetch_add(1, Ordering::Relaxed);
                        let want = wanted_bytes(r.query);
                        let mut bytes = [0u8; TRNG_MAX];

                        // The two numbers exp161 exists to produce, kept apart:
                        // how long the queue was, and how long the work took.
                        let asked = Instant::now();
                        let mut guard = RNG.lock().await;
                        let waited = (Instant::now() - asked).as_micros();
                        let began = Instant::now();
                        if let Some(trng) = guard.as_mut() {
                            trng.fill_bytes(&mut bytes[..want]).await;
                        }
                        let took = (Instant::now() - began).as_micros();
                        drop(guard);

                        log_transient!("http: /trng {} bytes, waited {} us, took {} us", want, waited, took);
                        (200, "text/plain; charset=utf-8",
                         render_trng(page, &bytes[..want], took, waited), Cors::Open)
                    }

                    // ---- the open door -------------------------------------
                    //
                    // **No header is consulted.** Any page in any browser that
                    // can route to this board can pull this, with an `<img>`
                    // tag it does not even need to be able to read the reply
                    // of; and `POST` is no better, because a cross-site form
                    // submission is not preflighted either. That is not a bug
                    // to be fixed in a later commit — it is the measurement,
                    // and the README carries what a browser actually did.
                    (Method::Get | Method::Post, Route::Led(lamp)) => {
                        COUNT_LED.fetch_add(1, Ordering::Relaxed);
                        let changed = set_lamp(lamp);
                        // A state change is history; the same state again is
                        // the caller's own repetition. exp153's rule, and the
                        // reason a page polling this cannot erase the log.
                        if changed {
                            log!("led: {} via {} from {}", lamp.word(),
                                 if matches!(r.method, Method::Get) { "GET" } else { "POST" },
                                 if origin_seen.is_empty() { "no stated origin" } else { origin_seen.as_str() });
                        } else {
                            log_transient!("led: {} again", lamp.word());
                        }
                        (200, "text/plain; charset=utf-8", render_lamp(page, lamp, true, ""), Cors::Open)
                    }

                    // ---- the door that asks who is knocking ----------------
                    //
                    // Two conditions, and neither is a secret: a header nothing
                    // adds by accident, and an `Origin` that is this board's
                    // own or absent. The header is what forces a browser to
                    // *preflight* — to ask before it acts — and the origin
                    // check is the answer it gets.
                    (Method::Post, Route::Control(lamp)) => {
                        let has_token = h.get(CONTROL_HEADER) == Some("1");
                        if has_token && ours {
                            COUNT_CONTROL.fetch_add(1, Ordering::Relaxed);
                            let changed = set_lamp(lamp);
                            if changed {
                                log!("led: now {} — asked through the guarded door", lamp.word());
                            }
                            (200, "text/plain; charset=utf-8",
                             render_lamp(page, lamp, true, ""), Cors::Allowed)
                        } else {
                            COUNT_TURNED_AWAY.fetch_add(1, Ordering::Relaxed);
                            let why = if !has_token {
                                "no X-Yi26-Control header"
                            } else {
                                "that origin is not mine"
                            };
                            log!("led: turned away, {}", why);
                            log!("  it said it was {}",
                                 if origin_seen.is_empty() { "nobody in particular" } else { origin_seen.as_str() });
                            (403, "text/plain; charset=utf-8",
                             render_lamp(page, lamp, false, why), Cors::Denied)
                        }
                    }

                    // ---- the question a browser asks first -----------------
                    //
                    // A preflight. Answering it with the origin echoed back is
                    // the board saying yes; answering without those headers is
                    // the board saying nothing, and a browser treats silence as
                    // no. **Nothing is done here** — a preflight must never be
                    // the thing that changes the board.
                    (Method::Options, Route::Control(_)) => {
                        if ours {
                            (204, "text/plain; charset=utf-8", 0, Cors::Preflight)
                        } else {
                            COUNT_TURNED_AWAY.fetch_add(1, Ordering::Relaxed);
                            log!("led: refused a preflight from {}",
                                 if origin_seen.is_empty() { "nobody in particular" } else { origin_seen.as_str() });
                            (403, "text/plain; charset=utf-8",
                             render_error(page, 403, "not this board's origin"), Cors::Denied)
                        }
                    }

                    // Parsed, well-formed, and names nothing. A 404 and not a
                    // 400 — one means "you asked for something that is not
                    // here", the other "I could not tell what you asked".
                    (Method::Get, _) => {
                        COUNT_REFUSED.fetch_add(1, Ordering::Relaxed);
                        log_transient!("http: 404 for a path of {} bytes", r.path.len());
                        (404, "text/plain; charset=utf-8",
                         render_error(page, 404, "no such path"), Cors::Open)
                    }
                    // A method this route does not answer — POST /log, or a
                    // preflight for something that cannot be written anyway.
                    (Method::Post | Method::Options, _) => {
                        COUNT_REFUSED.fetch_add(1, Ordering::Relaxed);
                        log_transient!("http: 405 for that method on that path");
                        (405, "text/plain; charset=utf-8",
                         render_error(page, 405, Refusal::MethodNotAllowed.reason()), Cors::Open)
                    }
                }
            }
        };

        head.clear();
        // Two headers that are a decision, not boilerplate.
        //
        // `Access-Control-Allow-Origin: *` lets a page that did not come from
        // this board *read* the response, instead of only being told the
        // request failed. That is what makes `reach.html` able to say "HTTP
        // 200, 792 bytes" rather than "something went wrong" — and asking
        // somebody to describe what went wrong is the thing this repository
        // spends its round trips escaping.
        //
        // It is a real loosening and it is worth naming: any page that can
        // route to this board can now read these pages. What is on them is a
        // chip ID, an uptime, a counter, a log this firmware wrote, and random
        // bytes. **Every route here reads.** The day one of them changes
        // something, this header stops being a convenience and becomes the
        // question — which is exactly what exp155 measures rather than assumes.
        //
        // `Allow-Private-Network` is Chrome's Private Network Access check: a
        // page on a secure origin fetching a private address is preflighted,
        // and without this the preflight fails before the request is made. It
        // is sent on every response because this server answers every method
        // the same way, preflight included.
        let reason = match status {
            200 => "OK",
            204 => "No Content",
            400 => "Bad Request",
            403 => "Forbidden",
            404 => "Not Found",
            405 => "Method Not Allowed",
            _ => "Error",
        };
        let _ = write!(
            head,
            "HTTP/1.0 {} {}\r\nContent-Type: {}\r\nContent-Length: {}\r\n",
            status, reason, ctype, len
        );
        // The CORS headers are now **four different answers**, and which one is
        // sent is the point of the experiment.
        //
        // `Cors::Open` on the reading routes is exp151's decision, inherited:
        // any page may read a chip ID, an uptime and a log. `Cors::Allowed`
        // echoes one origin — this board's own — rather than `*`, because `*`
        // on a route that writes would hand the door to every page there is.
        // `Cors::Denied` sends nothing at all: a browser reads silence as no,
        // and there is no header that means "no" more clearly than the absence
        // of the one that means yes.
        //
        // `Allow-Private-Network` is Chrome's Private Network Access check: a
        // page on a public origin fetching a private address is preflighted,
        // and without this that preflight fails before the request is made.
        match cors {
            Cors::Open => {
                let _ = write!(head, "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Private-Network: true\r\n");
            }
            // A request with no `Origin` is not a cross-origin request, so it
            // needs no permission and gets no header. **Echoing the literal
            // `null` here would have been a real mistake**, and it was caught
            // by looking at what `curl` was actually sent: `null` is not the
            // absence of an origin, it is the origin a sandboxed iframe and a
            // `file://` page carry — so a board that answers `null` has granted
            // exactly the callers least able to say who they are.
            Cors::Allowed if !origin_seen.is_empty() => {
                let _ = write!(head, "Access-Control-Allow-Origin: {}\r\nVary: Origin\r\n", origin_seen.as_str());
            }
            Cors::Allowed => {}
            Cors::Preflight => {
                if !origin_seen.is_empty() {
                    let _ = write!(head, "Access-Control-Allow-Origin: {}\r\nVary: Origin\r\n", origin_seen.as_str());
                }
                let _ = write!(
                    head,
                    "Access-Control-Allow-Methods: POST\r\nAccess-Control-Allow-Headers: {}\r\n\
Access-Control-Allow-Private-Network: true\r\nAccess-Control-Max-Age: 60\r\n",
                    CONTROL_HEADER
                );
            }
            // Deliberately nothing.
            Cors::Denied => {}
        }
        let _ = write!(head, "Connection: close\r\n\r\n");

        let ok = socket.write_all(head.as_bytes()).await.is_ok()
            && socket.write_all(&page[..len]).await.is_ok()
            && socket.flush().await.is_ok();
        if ok {
            log_transient!("http: #{} answered {} ({} bytes)", served, status, len);
        } else {
            log_transient!("http: #{} was not delivered", served);
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
    config.product = Some("exp155 who else can knock");
    config.serial_number = Some("155");
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

    // The fifth interface, and it is the fifth and not the sixth: **a
    // mass-storage function is one interface with two endpoints**. CDC-ACM is
    // two interfaces, CDC-NCM is two, and this is one — five, which is why
    // `max-interface-count-8` is set rather than inherited from the default of
    // four. exp152 and exp153 called this "the fifth and sixth" and were wrong;
    // `lsusb` says five, and the count is in the README beside the reading.
    let (msc_out, msc_in) = {
        let mut function = builder.function(CLASS_MSC, SUBCLASS_SCSI, PROTOCOL_BOT);
        let mut interface = function.interface();
        let mut alt = interface.alt_setting(CLASS_MSC, SUBCLASS_SCSI, PROTOCOL_BOT, None);
        let out = alt.endpoint_bulk_out(None, PACKET as u16);
        let in_ = alt.endpoint_bulk_in(None, PACKET as u16);
        (out, in_)
    };

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

    // And then it is handed to the workers rather than dropped, which is new
    // here. exp148 through exp153 used the TRNG once, to seed the stack, and
    // let it go. `/trng` gives it a second consumer that arrives at
    // unpredictable times and can arrive four at once, so from here on it lives
    // behind a lock — and the queue at that lock is the second thing this
    // experiment measures.
    *RNG.lock().await = Some(trng);

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
    static RESOURCES: StaticCell<StackResources<7>> = StaticCell::new();
    let (stack, net_runner) = embassy_net::new(
        device,
        net_config(),
        RESOURCES.init(StackResources::new()),
        u64::from_le_bytes(seed),
    );
    spawner.spawn(net_task(net_runner).unwrap());
    // One pair of buffers per worker, named separately so it is obvious there
    // are two of them and not one shared by accident.
    // One `StaticCell` per buffer and not a `StaticCell<[[u8; N]; 4]>`, because
    // `init()` panics the second time it is called and a loop over one cell is
    // exactly that mistake with extra steps.
    // A third buffer per worker: the rendered page. `usb_log::retained` runs
    // inside a critical section and cannot `.await`, so the log is copied out
    // in one go and written afterwards. RETAIN_LINES x LINE_CAPACITY is about
    // 6 KiB of text, and the markup around it is small.
    static RX: [StaticCell<[u8; 1024]>; 4] = [const { StaticCell::new() }; 4];
    static TX: [StaticCell<[u8; 2048]>; 4] = [const { StaticCell::new() }; 4];
    static PAGE: [StaticCell<[u8; 8192]>; 4] = [const { StaticCell::new() }; 4];
    for ((rx, tx), page) in RX.iter().zip(TX.iter()).zip(PAGE.iter()) {
        spawner.spawn(
            http_task(stack, rx.init([0; 1024]), tx.init([0; 2048]), page.init([0; 8192])).unwrap(),
        );
    }
    // The disk's bytes. Left zeroed on purpose: nothing is laid down into them
    // until the board knows its address, and until then the medium does not
    // exist as far as the host is concerned.
    static DISK: StaticCell<[u8; DISK_BYTES]> = StaticCell::new();
    spawner.spawn(storage_task(msc_out, msc_in, DISK.init([0; DISK_BYTES])).unwrap());
    spawner.spawn(pin_task(stack).unwrap());
    spawner.spawn(mdns_task(stack).unwrap());
    spawner.spawn(report_task(stack).unwrap());

    log!("exp155 up. The LED can now be set over HTTP, and the log says by whom.");

        // The client role cannot print its address here: it does not have one yet,
    // and will not for a few hundred milliseconds. The reporter prints it once
    // it arrives, and keeps printing it — because the line somebody is going to
    // read off `log.html` and type into a browser must not have scrolled away
    // by the time they look.
    {
        log!("  asking for an address — whoever is on the other end is the server here.");
        log!("  port {}: / /log /status /trng /led/<on|off|slow|fast|auto>.", HTTP_PORT);
        log!("  /led is open to whoever can route here.");
        log!("  /control/led needs a header and an origin that is mine.");
        log!("  and answering to yi26.local, so nobody has to know the number.");
        log!("  LED before an address: dark=no link, slow=asking. After it, yours.");
    }

    // **The LED is handed over, and only after there is an address.**
    //
    // Before that it goes on meaning what exp148 through exp153 and exp161 made it mean —
    // dark for no link, slow for still asking — because those are the two
    // states somebody is watching when nothing else can tell them anything, and
    // a page that could take them away would be taking away the instrument at
    // exactly the moment it is the only one there is.
    //
    // Once an address exists, a browser can reach the board, and the four
    // network states have already said everything they can say: being able to
    // ask at all proves the link and the lease. So from there the LED is the
    // caller's, until somebody asks for `/led/auto` back.
    //
    // The consequence is worth stating rather than hiding: **a page can set the
    // LED to something indistinguishable from a network state.** `slow` looks
    // like "still asking" and `off` looks like "no link". That is not a flaw in
    // the mechanism, it is what handing over an instrument means, and it is why
    // the handover does not start until the network states are moot.
    loop {
        let network_state = (stack.is_link_up(), addressed(stack), SERVED.load(Ordering::Relaxed));
        let told = if network_state.1 { lamp_of(LAMP.load(Ordering::Relaxed)) } else { Lamp::Auto };
        match told {
            Lamp::On => {
                led.set_high();
                Timer::after(POLL).await;
            }
            Lamp::Off => {
                led.set_low();
                Timer::after(POLL).await;
            }
            Lamp::Slow => blink(&mut led, BLINK_LINK).await,
            Lamp::Fast => blink(&mut led, BLINK_LEASED).await,
            // Nobody has asked, or the address went away. Four states, and the
            // fourth is not a fourth *rate*: three blink speeds is already more
            // than somebody can tell apart across a room, so "a browser got the
            // page" is solid on.
            Lamp::Auto => match network_state {
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
            },
        }
    }
}


async fn blink(led: &mut Output<'static>, half: Duration) {
    led.set_high();
    Timer::after(half).await;
    led.set_low();
    Timer::after(half).await;
}
const CLASS_MSC: u8 = 0x08;
const SUBCLASS_SCSI: u8 = 0x06;
const PROTOCOL_BOT: u8 = 0x50;

const CBW_SIGNATURE: u32 = 0x4342_5355;
const CSW_SIGNATURE: u32 = 0x5342_5355;
const CBW_LEN: usize = 31;
const CSW_LEN: usize = 13;
const CBW_FLAG_IN: u8 = 0x80;

const CSW_GOOD: u8 = 0x00;
const CSW_FAILED: u8 = 0x01;

/// 512 bytes, because everything above assumes it.
///
/// A SCSI disk may declare any block size and `READ CAPACITY` says which. In
/// practice partition tables, filesystems and the tools that read them are
/// written for 512, and a device that picks something else discovers how much
/// software only *believes* it is asking.
const BLOCK: usize = 512;

/// A small disk, entirely in RAM.
///
/// 64 KiB is enough to be a real volume with a real partition sector, small
/// enough to sit in SRAM without thought, and distinctive in `lsblk` — a
/// removable disk that size is unmistakably this experiment and not somebody's
/// USB stick.
const DISK_BLOCKS: u32 = 128;
const DISK_BYTES: usize = DISK_BLOCKS as usize * BLOCK;

/// The repository's log tool, embedded from the file itself.
///
/// UNIT ATTENTION / NOT READY TO READY CHANGE, MEDIUM MAY HAVE CHANGED.
///
/// The whole vocabulary this experiment adds. `0x06` is the key a device uses
/// to say *something happened that you were not told about*, and `0x28` is the
/// one that means the medium is not the medium you were reading.

/// SCSI sense, kept so that `REQUEST SENSE` can answer the question the host
/// asks after a command is refused. Two atomics rather than a struct because
/// they are written from one task and read from the same one.
static SENSE_KEY: AtomicU32 = AtomicU32::new(0);
static SENSE_ASC: AtomicU32 = AtomicU32::new(0);

/// Set when the medium appears, reported once on the next command that is
/// neither INQUIRY nor REQUEST SENSE.
static MEDIA_CHANGED: AtomicBool = AtomicBool::new(false);

/// `TEST UNIT READY` arrives about twice a second forever, so it is counted
/// rather than logged — exp137 buried its own measurement under those lines
/// once and this firmware inherits the lesson.
static POLLS: AtomicU32 = AtomicU32::new(0);
/// The same poll, answered "there is no disk". Counting it separately is how
/// the log shows how long the host was kept waiting.
static NOT_READY_POLLS: AtomicU32 = AtomicU32::new(0);

static COMMANDS: AtomicU32 = AtomicU32::new(0);
static BLOCKS_READ: AtomicU32 = AtomicU32::new(0);
static BLOCKS_WRITTEN: AtomicU32 = AtomicU32::new(0);

/// NOT READY / MEDIUM NOT PRESENT — a card reader with no card in it.
const SENSE_NOT_READY: u32 = 0x02;
const ASC_MEDIUM_NOT_PRESENT: u32 = 0x3a;

const SENSE_UNIT_ATTENTION: u32 = 0x06;
const ASC_MEDIUM_MAY_HAVE_CHANGED: u32 = 0x28;

/// DATA PROTECT / WRITE PROTECTED, for a volume that declared itself read-only.
const SENSE_DATA_PROTECT: u32 = 0x07;
const ASC_WRITE_PROTECTED: u32 = 0x27;

/// ILLEGAL REQUEST / INVALID COMMAND OPERATION CODE.
const SENSE_ILLEGAL_REQUEST: u32 = 0x05;
const ASC_INVALID_COMMAND: u32 = 0x20;
/// ILLEGAL REQUEST / LOGICAL BLOCK ADDRESS OUT OF RANGE.
const ASC_LBA_OUT_OF_RANGE: u32 = 0x21;

fn le_u32(b: &[u8]) -> u32 {
    u32::from_le_bytes([b[0], b[1], b[2], b[3]])
}

/// SCSI's byte order, and the reason this has a name of its own.
fn be_u32(b: &[u8]) -> u32 {
    u32::from_be_bytes([b[0], b[1], b[2], b[3]])
}

fn be_u16(b: &[u8]) -> u16 {
    u16::from_be_bytes([b[0], b[1]])
}

fn opcode_name(op: u8) -> &'static str {
    match op {
        0x00 => "TEST UNIT READY",
        0x03 => "REQUEST SENSE",
        0x12 => "INQUIRY",
        0x1a => "MODE SENSE(6)",
        0x1b => "START STOP UNIT",
        0x1e => "PREVENT ALLOW MEDIUM REMOVAL",
        0x23 => "READ FORMAT CAPACITIES",
        0x25 => "READ CAPACITY(10)",
        0x28 => "READ(10)",
        0x2a => "WRITE(10)",
        0x35 => "SYNCHRONIZE CACHE(10)",
        0x5a => "MODE SENSE(10)",
        _ => "unsupported",
    }
}

fn set_sense(key: u32, asc: u32) {
    SENSE_KEY.store(key, Ordering::Relaxed);
    SENSE_ASC.store(asc, Ordering::Relaxed);
}

/// The 36-byte answer to "what are you".
///
/// The strings are fixed-width and space-padded, not NUL-terminated — SCSI
/// predates that convention. `lsblk` prints them as VENDOR and MODEL, so this
/// is where the name in the disk listing comes from.
/// The two strings a host shows in its disk listing.
///
/// Named once and used twice — in the bytes that go out and in the line that
/// says what went out. They were literals in both places for one build, the
/// bytes were updated and the log line was not, and the firmware spent that
/// build reporting a product name it was not sending. A log that disagrees
/// with the artifact is the failure this repository keeps meeting.
const INQUIRY_VENDOR: &[u8; 8] = b"yi26    ";
const INQUIRY_PRODUCT: &[u8; 16] = b"exp155 knocking ";

fn inquiry(out: &mut [u8]) -> usize {
    out[..36].fill(0);
    out[0] = 0x00; // peripheral qualifier 0, direct-access block device
    out[1] = 0x80; // removable
    out[2] = 0x02; // SCSI-2
    out[3] = 0x02; // response data format 2
    out[4] = 31; // additional length: 36 - 5
    out[8..16].copy_from_slice(INQUIRY_VENDOR);
    out[16..32].copy_from_slice(INQUIRY_PRODUCT);
    out[32..36].copy_from_slice(b"0001");
    36
}

/// Fixed-format sense data: what went wrong with the previous command.
fn request_sense(out: &mut [u8]) -> usize {
    out[..18].fill(0);
    out[0] = 0x70; // current error, fixed format
    out[2] = SENSE_KEY.load(Ordering::Relaxed) as u8;
    out[7] = 10; // additional sense length
    out[12] = SENSE_ASC.load(Ordering::Relaxed) as u8;
    18
}

/// Last addressable block and block size — both big-endian.
///
/// `DISK_BLOCKS - 1`, not `DISK_BLOCKS`. READ CAPACITY reports the address of
/// the last block, not how many there are, and an off-by-one here is a disk
/// that is one block too large: the host will eventually read past the end and
/// find out.
fn read_capacity(out: &mut [u8]) -> usize {
    out[0..4].copy_from_slice(&(DISK_BLOCKS - 1).to_be_bytes());
    out[4..8].copy_from_slice(&(BLOCK as u32).to_be_bytes());
    8
}

/// A four-byte mode parameter header and no pages.
///
/// Byte 2 carries the write-protect bit, which is the only thing in here the
/// host cares about.
///
/// Set here, unlike exp126, and for this experiment's own reason: a volume
/// that is laid down again from the device side would silently eat whatever
/// the host had written. Declaring it read-only means the host never writes,
/// so "the volume changed" has exactly one cause and the measurement has one
/// variable. exp130 established that a host which reads this bit does honour
/// it.
fn mode_sense6(out: &mut [u8]) -> usize {
    out[..4].fill(0);
    out[0] = 3; // mode data length, not counting itself
    out[2] = 0x80; // WP
    4
}

async fn send_csw(
    write_ep: &mut Endpoint<'static, USB, In>,
    tag: u32,
    residue: u32,
    status: u8,
) -> bool {
    let mut csw = [0u8; CSW_LEN];
    csw[0..4].copy_from_slice(&CSW_SIGNATURE.to_le_bytes());
    csw[4..8].copy_from_slice(&tag.to_le_bytes());
    csw[8..12].copy_from_slice(&residue.to_le_bytes());
    csw[12] = status;
    write_ep.write(&csw).await.is_ok()
}

/// Reads command wrappers, serves them, and reports.
#[embassy_executor::task]
async fn storage_task(
    mut read_ep: Endpoint<'static, USB, Out>,
    mut write_ep: Endpoint<'static, USB, In>,
    disk: &'static mut [u8],
) -> ! {
    let mut buf = [0u8; PACKET];
    let mut reply = [0u8; 64];

    loop {
        read_ep.wait_enabled().await;

        loop {
            let n = match read_ep.read(&mut buf).await {
                Ok(n) => n,
                Err(_) => break,
            };
            if n != CBW_LEN || le_u32(&buf[0..4]) != CBW_SIGNATURE {
                log!("not a CBW: {} bytes", n);
                continue;
            }

            // Before anything is answered: if the address has arrived since
            // the last command, this is the only place allowed to build the
            // volume, because this task owns the bytes.
            if let Some(addr) = PENDING_VOLUME.take() {
                let clusters = lay_down(disk, addr);
                READY.store(true, Ordering::Relaxed);
                MEDIA_CHANGED.store(true, Ordering::Relaxed);
                log_transient!(
                    "volume: laid down for {}.{}.{}.{}, {} clusters used — the medium exists now",
                    addr[0], addr[1], addr[2], addr[3], clusters
                );
            }

            // Everything this task says about *serving* the disk is transient.
            //
            // The third time this pattern has come up, and the clearest: the
            // page a person opens is reached by opening the drive, and opening
            // the drive is a hundred READ(10) commands. The first phone to run
            // this saw its own arrival — READ(10), PREVENT ALLOW MEDIUM
            // REMOVAL, over and over — with the boot lines pushed out behind
            // it. exp151 had it with HTTP requests and with mDNS chatter.
            //
            // The rule, now that it has been paid for three times:
            // **anything that exists only because somebody is reading the log
            // does not belong in the log.** The serial port still gets all of
            // it, because somebody watching a serial port is watching the
            // mechanism on purpose.
            let tag = le_u32(&buf[4..8]);
            let want = le_u32(&buf[8..12]);
            let to_host = buf[12] & CBW_FLAG_IN != 0;
            let cb = [
                buf[15], buf[16], buf[17], buf[18], buf[19], buf[20], buf[21], buf[22], buf[23],
                buf[24],
            ];
            let op = cb[0];
            COMMANDS.fetch_add(1, Ordering::Relaxed);

            let mut status = CSW_GOOD;
            let mut sent: u32 = 0;

            // The media change, reported exactly once, on whatever command
            // happens to arrive next.
            //
            // Two commands are exempt and the exemption is not politeness.
            // `INQUIRY` asks what the device *is*, which a medium cannot
            // change, and `REQUEST SENSE` is how the host collects the reason
            // for the failure — failing that one would hide the very message
            // being sent. Everything else is refused, the host asks why, and
            // the answer is `06/28`.
            //
            // What it costs the host to ignore this is nothing: it is a
            // notification, not an instruction. Whether any host acts on it is
            // the measurement, and the firmware's job is only to have said it.
            if MEDIA_CHANGED.load(Ordering::Relaxed) && op != 0x12 && op != 0x03 {
                MEDIA_CHANGED.store(false, Ordering::Relaxed);
                set_sense(SENSE_UNIT_ATTENTION, ASC_MEDIUM_MAY_HAVE_CHANGED);
                status = CSW_FAILED;
                log_transient!(
                    "{}  -> UNIT ATTENTION (06/28): the medium may have changed",
                    opcode_name(op)
                );
                // A failed command still owes the host its data phase, even
                // though there is no data. exp124 learned this the hard way:
                // a host that asked for bytes and is given neither bytes nor
                // a refusal simply waits.
                if want > 0 && to_host {
                    let _ = write_ep.write(&[]).await;
                }
                if !send_csw(&mut write_ep, tag, want, status).await {
                    break;
                }
                continue;
            }

            // Anything that assumes a medium is refused the same way, and for
            // the same reason: a host told the capacity of a disk that does not
            // exist yet will happily mount it.
            if !READY.load(Ordering::Relaxed) && matches!(op, 0x25 | 0x28 | 0x2a | 0x23) {
                set_sense(SENSE_NOT_READY, ASC_MEDIUM_NOT_PRESENT);
                if want > 0 && to_host {
                    let _ = write_ep.write(&[]).await;
                }
                if !send_csw(&mut write_ep, tag, want, CSW_FAILED).await {
                    break;
                }
                continue;
            }

            match op {
                // No data, and the answer is "yes" because there is a disk.
                //
                // `TEST UNIT READY` is not logged, and that is a change this
                // experiment forced. A host polls it about twice a second
                // forever — it is how a host asks "is the medium still the
                // one I know about" — so logging it costs the log. The first
                // run of this firmware buried its own measurement under 135
                // dropped lines, which is exp134's queue arriving as a
                // consequence for the second time. Counted here, reported in
                // the idle line, never printed on its own.
                // TEST UNIT READY, and the whole experiment turns on this arm.
                //
                // Until the board knows its address there is no medium, and
                // saying so is not a stall: `NOT READY / MEDIUM NOT PRESENT` is
                // the answer a card reader with no card gives, and hosts know
                // what to do with it — nothing. They wait, and they mount
                // nothing, so there is no cache for a later answer to be stale
                // against.
                0x00 => {
                    if READY.load(Ordering::Relaxed) {
                        set_sense(0, 0);
                        POLLS.fetch_add(1, Ordering::Relaxed);
                    } else {
                        set_sense(SENSE_NOT_READY, ASC_MEDIUM_NOT_PRESENT);
                        status = CSW_FAILED;
                        NOT_READY_POLLS.fetch_add(1, Ordering::Relaxed);
                    }
                }

                0x1b | 0x1e | 0x35 => {
                    set_sense(0, 0);
                    log_transient!("{}  -> ok", opcode_name(op));
                }

                0x12 => {
                    let len = inquiry(&mut reply).min(want as usize);
                    let _ = write_ep.write(&reply[..len]).await;
                    sent = len as u32;
                    set_sense(0, 0);
                    log_transient!(
                        "INQUIRY  -> {} bytes: {} / {}",
                        len,
                        core::str::from_utf8(INQUIRY_VENDOR).unwrap_or("?").trim_end(),
                        core::str::from_utf8(INQUIRY_PRODUCT).unwrap_or("?").trim_end()
                    );
                }

                0x03 => {
                    let len = request_sense(&mut reply).min(want as usize);
                    let _ = write_ep.write(&reply[..len]).await;
                    sent = len as u32;
                    log_transient!(
                        "REQUEST SENSE  -> key {} asc {:02x}",
                        SENSE_KEY.load(Ordering::Relaxed),
                        SENSE_ASC.load(Ordering::Relaxed)
                    );
                }

                0x25 => {
                    let len = read_capacity(&mut reply).min(want as usize);
                    let _ = write_ep.write(&reply[..len]).await;
                    sent = len as u32;
                    set_sense(0, 0);
                    log_transient!(
                        "READ CAPACITY  -> last LBA {}, {} bytes each = {} KiB",
                        DISK_BLOCKS - 1,
                        BLOCK,
                        DISK_BYTES / 1024
                    );
                }

                0x1a => {
                    let len = mode_sense6(&mut reply).min(want as usize);
                    let _ = write_ep.write(&reply[..len]).await;
                    sent = len as u32;
                    set_sense(0, 0);
                    log_transient!("MODE SENSE(6)  -> READ-ONLY (WP set), no pages");
                }

                0x2a => {
                    // Refused with a reason, not ignored. The host asked to
                    // write to a volume that told it not to, and the only
                    // useful answer names the rule it broke.
                    set_sense(SENSE_DATA_PROTECT, ASC_WRITE_PROTECTED);
                    status = CSW_FAILED;
                    log!("WRITE(10)  -> DATA PROTECT / WRITE PROTECTED");
                }

                0x28 => {
                    let lba = be_u32(&cb[2..6]);
                    let count = be_u16(&cb[7..9]) as u32;
                    let reading = op == 0x28;

                    if lba.saturating_add(count) > DISK_BLOCKS {
                        // The failure that matters most, and the one a
                        // dishonest READ CAPACITY causes: refuse it precisely
                        // rather than reading off the end of an array.
                        set_sense(SENSE_ILLEGAL_REQUEST, ASC_LBA_OUT_OF_RANGE);
                        status = CSW_FAILED;
                        log!("{} lba {} +{}  -> OUT OF RANGE", opcode_name(op), lba, count);
                    } else {
                        let start = lba as usize * BLOCK;
                        let end = start + count as usize * BLOCK;
                        if reading {
                            for chunk in disk[start..end].chunks(PACKET) {
                                if write_ep.write(chunk).await.is_err() {
                                    break;
                                }
                            }
                            sent = (end - start) as u32;
                            BLOCKS_READ.fetch_add(count, Ordering::Relaxed);
                        } else {
                            let mut at = start;
                            while at < end {
                                match read_ep.read(&mut buf).await {
                                    Ok(got) => {
                                        let take = got.min(end - at);
                                        disk[at..at + take].copy_from_slice(&buf[..take]);
                                        at += take.max(1);
                                    }
                                    Err(_) => break,
                                }
                            }
                            sent = (end - start) as u32;
                            BLOCKS_WRITTEN.fetch_add(count, Ordering::Relaxed);
                        }
                        set_sense(0, 0);
                        log_transient!("{} lba {} +{} blocks", opcode_name(op), lba, count);
                    }
                }

                // Everything else is refused with a reason the host can read.
                // exp123 refused these too, and refused REQUEST SENSE as well,
                // which is why its host learned nothing and retried.
                _ => {
                    set_sense(SENSE_ILLEGAL_REQUEST, ASC_INVALID_COMMAND);
                    status = CSW_FAILED;
                    if want > 0 && to_host {
                        let _ = write_ep.write(&[]).await;
                    }
                    log!("{:02x} {}  -> refused, invalid command", op, opcode_name(op));
                }
            }

            // A short reply is not a failure. The residue says how much of the
            // requested transfer did not happen, and a host that asked for 36
            // bytes and got 36 sees zero residue.
            if !send_csw(&mut write_ep, tag, want.saturating_sub(sent), status).await {
                break;
            }
        }
    }
}

/// What the drive carries. Written once, when the address is known.
///
/// `OPEN.HTM` is the whole point: a page whose only content is a link. A phone's
/// address bar searches for what it is given — measured, `http://yi26.local/`
/// went to Google — so the address has to be **tappable rather than typable**. A
/// link is a top-level navigation, which is the one thing exp150 measured going
/// through from a `content://` page: a `fetch` and an `<iframe>` are both
/// refused as mixed content, and a navigation is not.
///
/// This is exp152's mechanism, unchanged, and it is here for a reason exp161
/// could do without: **a page that controls the board is no use to somebody who
/// cannot find the board.** Without a drive, the address lives only in the CDC
/// log, and reading that on a phone needs WebUSB — Chromium only, which is the
/// thing this whole road exists to escape.
fn lay_down(disk: &mut [u8], addr: [u8; 4]) -> u32 {
    let mut page = [0u8; 1024];
    let mut w = Cursor { buf: &mut page, n: 0 };
    let _ = write!(
        w,
        "<!doctype html><meta charset=utf-8>\
<meta name=viewport content=\"width=device-width,initial-scale=1\">\
<title>Open the board</title>\
<style>body{{font:16px/1.6 system-ui,sans-serif;margin:0 auto;max-width:30rem;padding:2rem 1rem}}\
a{{display:block;text-align:center;font:600 1.2rem/1 system-ui,sans-serif;padding:1.3rem;\
border-radius:10px;background:#1a5fb4;color:#fff;text-decoration:none;margin:1.5rem 0}}\
p{{color:#666}}</style>\
<h1>The board is at this address</h1>\
<p>This drive came off the board, and so did the address below. Tap it &mdash; \
do not type it, because a phone's address bar will search for it instead.</p>\
<a href=\"http://{}.{}.{}.{}/\">http://{}.{}.{}.{}/</a>\
<p>On that page: five links that change the LED on the board in your hand, the \
firmware's own log, and its status. Nothing is installed and nothing claimed a \
device &mdash; it is one USB cable carrying all three.</p>",
        addr[0], addr[1], addr[2], addr[3], addr[0], addr[1], addr[2], addr[3]
    );
    let page_len = w.n;
    // A `Cursor` truncates silently — that is its bargain, and it is the right
    // one for a log line. For a page it is a trap, and exp153 fell into it: at
    // 640 bytes the buffer filled exactly, the link's `href` survived because it
    // comes first, and the text after it was cut mid-address. The phone showed a
    // working button labelled `http://10`.
    //
    // A buffer that truncates in silence needs something that breaks the
    // silence, so this says so — and the buffer is 1024 rather than 640.
    if page_len == page.len() {
        log!("volume: OPEN.HTM filled its buffer exactly — it is probably truncated");
    }

    let mut text = [0u8; 96];
    let mut w = Cursor { buf: &mut text, n: 0 };
    let _ = write!(w, "http://{}.{}.{}.{}/\r\n", addr[0], addr[1], addr[2], addr[3]);
    let text_len = w.n;

    fat12::format(
        disk,
        b"YI26 BOARD ",
        &[
            fat12::File { name: b"OPEN    HTM", contents: &page[..page_len] },
            fat12::File { name: b"ADDRESS TXT", contents: &text[..text_len] },
            fat12::File { name: b"README  TXT", contents: README },
        ],
    )
    .expect("checked by the crate's own tests")
}

const README: &[u8] = b"exp155 - who else can knock.\r\n\r\nOne USB cable, carrying a user interface, a control channel and a log at\r\nonce. Nothing is installed on your phone and nothing claimed a device: the\r\nboard serves an ordinary web page over the cable, and any browser can open\r\nit - no WebUSB, no permission dialog, no Chromium requirement.\r\n\r\nOPEN.HTM     tap the link. That page has the LED controls, the log and the\r\n             status on it.\r\nADDRESS.TXT  the same address as plain text, if you would rather read it.\r\n\r\nWhat to try, in the order that shows the point:\r\n\r\n  1. tap 'fast' - the LED on the board blinks fast, and you did not install\r\n     anything to make that happen\r\n  2. tap /log - the firmware's own log, including the line about the request\r\n     you just made\r\n  3. tap 'give it back' - the LED goes back to reporting the network\r\n\r\nTHE ORDER MATTERS. This drive did not exist until the phone gave the board\r\nan address, and the phone will not do that until you turn ON Ethernet\r\ntethering - which is greyed out until something is plugged in. So:\r\n\r\n  1. plug the board in\r\n  2. turn on Ethernet tethering, straight away\r\n  3. wait for the LED to blink fast; this drive appears then\r\n\r\nLeaving a long gap at step 2 is what goes wrong. The board keeps asking\r\nforever, but a host that has been told 'no medium' for long enough may\r\nstop looking.\r\n\r\nAbout that LED: until the board has an address it means something -\r\ndark is no link, slow blink is still asking. After that it is yours, which\r\nis why the controls only work once you can reach the page at all.\r\n\r\nWhat this experiment measured, if you want the rest of it: a page from\r\nSOMEBODY ELSE'S site can pull those same LED links with an <img> tag, and\r\nit works. CORS does not stop the request; it only stops the reply being\r\nread. The one door that refused is the one that made the browser ask first.\r\nREADME.md in this zip has the numbers.\r\n";
