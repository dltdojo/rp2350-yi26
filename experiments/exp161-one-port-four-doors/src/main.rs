//! exp161 — one port, four doors.
//!
//! Every experiment on this road so far has served **one thing**.
//! [exp150](../../exp150-a-page-served-by-the-board/) served a status page and
//! read the request line only to throw it away;
//! [exp151](../../exp151-the-log-in-any-browser/) replaced the page with the
//! log and threw the request away just the same. Both said why, in the same
//! comment:
//!
//! > Parsing a request line means parsing untrusted input in a firmware, and
//! > every path through this server returns the same page, so there is nothing
//! > a path could select. exp151 is where a URL starts to mean something, and
//! > that is where the parser belongs.
//!
//! Here a path selects something. Four of them:
//!
//! ```text
//!   /          what is on this board, and links to the rest
//!   /log       the retained log — exp151's page, unchanged
//!   /status    the same facts as JSON, for something that is not a person
//!   /trng      bytes from the hardware random number generator
//! ```
//!
//! # Why this is worth an experiment and not an afternoon
//!
//! Because two of the three things it teaches are only visible once there is
//! more than one door.
//!
//! **A truncation is not a 404.** A TCP read returns whatever has arrived, and
//! nothing promises a whole request line is in it. A parser that answers
//! "unknown path" to `GET /lo` hands back an answer that depends on how the
//! host's stack split the packet — the same class of bug `crates/dhcp` was
//! written to make testable, and the reason the parser here lives in
//! [`http-route`](../../../crates/http-route/) with `cargo test` cutting a
//! request at every offset.
//!
//! **Multiplexing is free until something is shared.** Four workers serve four
//! different paths at once with no interference — that part is what the async
//! executor is for. But `/trng` reaches for **the one TRNG this chip has**, and
//! there is exactly one of it behind a mutex, so a second `/trng` waits for the
//! first while `/log` beside it does not wait at all. The URL space is not the
//! thing that runs out. The peripheral is.
//!
//! # What this does and does not say about USB CDC
//!
//! It is tempting to summarise this experiment as "HTTP paths instead of
//! serial ports, because serial ports are scarce". That is not what this
//! repository measured, and the real finding is more useful:
//!
//! - **An interface has exactly one owner.** exp122 established it, exp131 was
//!   stopped dead by it — its appliance page held the only CDC pair, so the log
//!   page could not open at all — and exp132 built both ways round it to
//!   measure the difference. Adding a second CDC function is possible; what it
//!   does not do is let two programs read the same one.
//! - **A path costs nothing on the host.** No driver binds it, no device node
//!   appears, nobody has to work out which `/dev/ttyACM*` is the log and which
//!   is the control channel, and as many clients can ask at once as the stack
//!   has sockets.
//!
//! So the axis is **ownership versus dispatch**, not scarcity. What is bought
//! is stated in the README beside what it costs, and the cost is not small:
//! this firmware carries a TCP/IP stack, a DHCP client, an mDNS responder and
//! an HTTP parser that a CDC log does not need, and `http://` is not a secure
//! context, so the origin this board serves can never also use WebUSB.
//!
//! # What is deliberately not here
//!
//! **Writes.** Nothing on this board changes because of an HTTP request — every
//! route reads. The moment one of them writes, the question stops being "which
//! path" and becomes "who is allowed to ask", and that is
//! [exp155](../../exp155-who-else-can-knock/), which measures it rather than
//! asserting it.
//!
//! **`Host:` validation, and any header at all.** The parser reads the request
//! line and stops. That is a real gap with a name — DNS rebinding — and it
//! belongs to the experiment that has something worth rebinding *to*.
//!
//! # The LED is untouched
//!
//! Four states, exactly as exp153 left them: dark, slow, fast, solid. This is
//! the instrument the whole network road is read with on a phone —
//! [`docs/debugging-on-a-phone.md`](../../../docs/debugging-on-a-phone.md) —
//! and an experiment about URLs has no business spending it.

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
use embassy_rp::usb::{Driver, InterruptHandler};
use embassy_sync::blocking_mutex::raw::CriticalSectionRawMutex;
use embassy_sync::mutex::Mutex;
use embedded_io_async::Write as _;
use core::fmt::Write as _;
use core::sync::atomic::{AtomicU32, Ordering};
use embassy_time::{with_timeout, Duration, Instant, Timer};
use http_route::{Method, Parsed, Refusal, Request, Route};
use embassy_usb::class::cdc_acm::{CdcAcmClass, ControlChanged, Receiver, Sender, State as AcmState};
use embassy_usb::class::cdc_ncm::embassy_net::{Device, Runner as NcmRunner, State as NetDeviceState};
use embassy_usb::class::cdc_ncm::{CdcNcmClass, State as NcmState};
use embassy_usb::{Builder, Config as UsbConfig, UsbDevice};
use panic_halt as _;
use rp2350_linker as _;
use static_cell::StaticCell;
use usb_log::{log, log_transient};

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
    TRNG_IRQ => TrngInterruptHandler<TRNG>;
});

const PACKET: usize = 64;
const MTU: usize = 1514;

const HOST_MAC: [u8; 6] = [0x02, 0x26, 0x00, 0x00, 0x01, 0x61];
const OUR_MAC: [u8; 6] = [0x02, 0x26, 0x00, 0x00, 0x02, 0x61];

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
They move independently, which is the whole point.</p>",
        addr[0], addr[1], addr[2], addr[3],
        addr[0], addr[1], addr[2], addr[3], hi, lo, up,
        COUNT_LOG.load(Ordering::Relaxed),
        COUNT_STATUS.load(Ordering::Relaxed),
        TRNG_MAX,
        COUNT_TRNG.load(Ordering::Relaxed),
        COUNT_INDEX.load(Ordering::Relaxed),
        COUNT_REFUSED.load(Ordering::Relaxed),
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
    let _ = write!(
        w,
        "\"served\":{{\"index\":{},\"log\":{},\"status\":{},\"trng\":{},\"refused\":{}}},\
\"log_lines_lost\":{}}}",
        COUNT_INDEX.load(Ordering::Relaxed),
        COUNT_LOG.load(Ordering::Relaxed),
        COUNT_STATUS.load(Ordering::Relaxed),
        COUNT_TRNG.load(Ordering::Relaxed),
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
fn render_trng(out: &mut [u8], bytes: &[u8], took_us: u64, waited_us: u64) -> usize {
    let mut w = Cursor { buf: out, n: 0 };
    let _ = write!(
        w,
        "{} bytes from the RP2350 TRNG\n\
sampling took {} us; waiting for the one TRNG took {} us\n\n",
        bytes.len(), took_us, waited_us
    );
    for (i, b) in bytes.iter().enumerate() {
        let _ = write!(w, "{:02x}", b);
        w.byte(if (i + 1) % 32 == 0 { b'\n' } else { b' ' });
    }
    w.byte(b'\n');
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
    // Big enough for a request line and the first headers of a real browser,
    // and small enough that filling it is itself an answer: a client that has
    // sent this much without ending a line is not going to.
    let mut req = [0u8; 512];
    let mut head: heapless::String<256> = heapless::String::new();

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

        // Read until the first line is whole, the buffer is full, or the peer
        // stops talking. `have` is the only state this loop carries; the
        // request itself is re-parsed once afterwards, so that the borrow of
        // `req` never has to outlive the reads into it.
        let mut have = 0usize;
        let mut gone = false;
        let decided = loop {
            match http_route::parse(&req[..have]) {
                Parsed::Incomplete => {}
                other => break Some(matches!(other, Parsed::Complete(_))),
            }
            if have == req.len() {
                // A full buffer with no line in it. The parser refuses this on
                // length as soon as it is asked, so let it say so.
                break Some(false);
            }
            match with_timeout(REQUEST_TIMEOUT, socket.read(&mut req[have..])).await {
                Ok(Ok(0)) | Ok(Err(_)) => { gone = true; break None }
                Err(_) => {
                    log_transient!("http: no request line within {} s", REQUEST_TIMEOUT.as_secs());
                    gone = true;
                    break None;
                }
                Ok(Ok(n)) => have += n,
            }
        };
        if gone || decided.is_none() {
            socket.abort();
            continue;
        }

        let served = SERVED.fetch_add(1, Ordering::Relaxed) + 1;

        // One place where a path becomes an answer. Everything above this is
        // transport and everything below it is bytes; this match is the
        // experiment.
        let (status, ctype, len) = match http_route::parse(&req[..have]) {
            Parsed::Complete(Request { method: Method::Get, route: Route::Index, .. }) => {
                COUNT_INDEX.fetch_add(1, Ordering::Relaxed);
                (200, "text/html; charset=utf-8", render_index(page, my_address(stack).unwrap_or([0; 4])))
            }
            Parsed::Complete(Request { method: Method::Get, route: Route::Log, .. }) => {
                COUNT_LOG.fetch_add(1, Ordering::Relaxed);
                (200, "text/html; charset=utf-8", render(page, my_address(stack).unwrap_or([0; 4])))
            }
            Parsed::Complete(Request { method: Method::Get, route: Route::Status, .. }) => {
                COUNT_STATUS.fetch_add(1, Ordering::Relaxed);
                let cfg = stack.config_v4();
                let len = render_status(
                    page,
                    my_address(stack).unwrap_or([0; 4]),
                    cfg.and_then(|c| c.gateway).map(|g| g.octets()),
                    stack.is_link_up(),
                );
                (200, "application/json", len)
            }
            Parsed::Complete(Request { method: Method::Get, route: Route::Trng, query, .. }) => {
                COUNT_TRNG.fetch_add(1, Ordering::Relaxed);
                let want = wanted_bytes(query);
                let mut bytes = [0u8; TRNG_MAX];

                // The two numbers this experiment exists to produce, kept
                // apart: how long the queue was, and how long the work took.
                // A single "elapsed" would hide which of the two a second
                // caller is paying for.
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
                (200, "text/plain; charset=utf-8", render_trng(page, &bytes[..want], took, waited))
            }
            // Parsed, well-formed, and names nothing **on this firmware**. A 404
            // and not a 400 — the difference matters to whoever is reading the
            // log, because one of them means "you asked for something that is
            // not here" and the other means "I could not tell what you asked".
            //
            // `Route` has variants this experiment does not serve: exp155 added
            // `/led/…` to the shared table, and on this board those paths do not
            // exist. They land here, which is exactly right — a routing table is
            // allowed to know about doors a given firmware did not build.
            Parsed::Complete(Request { method: Method::Get, path, .. }) => {
                COUNT_REFUSED.fetch_add(1, Ordering::Relaxed);
                log_transient!("http: 404 for a path of {} bytes", path.len());
                (404, "text/plain; charset=utf-8", render_error(page, 404, "no such path"))
            }
            // A method this board parses and does not act on — POST /log, or a
            // preflight for a route that could not be written to anyway.
            // Nothing here writes, which is exp155's subject, so this is a 405
            // rather than a quiet success.
            Parsed::Complete(Request { method: Method::Post | Method::Options, .. }) => {
                COUNT_REFUSED.fetch_add(1, Ordering::Relaxed);
                log_transient!("http: 405 — nothing on this board is written by a request");
                (405, "text/plain; charset=utf-8", render_error(page, 405, Refusal::MethodNotAllowed.reason()))
            }
            Parsed::Refused(why) => {
                COUNT_REFUSED.fetch_add(1, Ordering::Relaxed);
                // The reason is logged and also sent. On a phone the log is
                // three taps away and the response body is on the screen.
                log_transient!("http: {} — {}", why.status(), why.reason());
                (why.status(), "text/plain; charset=utf-8", render_error(page, why.status(), why.reason()))
            }
            // Unreachable: the loop above only leaves with a decision.
            Parsed::Incomplete => {
                socket.abort();
                continue;
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
            400 => "Bad Request",
            404 => "Not Found",
            405 => "Method Not Allowed",
            _ => "Error",
        };
        let _ = write!(
            head,
            "HTTP/1.0 {} {}\r\nContent-Type: {}\r\n\
Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Private-Network: true\r\n\
Content-Length: {}\r\nConnection: close\r\n\r\n",
            status, reason, ctype, len
        );

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
    config.product = Some("exp161 one port four doors");
    config.serial_number = Some("161");
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
    spawner.spawn(pin_task(stack).unwrap());
    spawner.spawn(mdns_task(stack).unwrap());
    spawner.spawn(report_task(stack).unwrap());

    log!("exp161 up. One port, four paths: / /log /status /trng.");

        // The client role cannot print its address here: it does not have one yet,
    // and will not for a few hundred milliseconds. The reporter prints it once
    // it arrives, and keeps printing it — because the line somebody is going to
    // read off `log.html` and type into a browser must not have scrolled away
    // by the time they look.
    {
        log!("  asking for an address — whoever is on the other end is the server here.");
        log!("  port {}: / is the index, /log is this log, /status is JSON, /trng is bytes.", HTTP_PORT);
        log!("  /trng takes ?n= up to {}, and shares one TRNG between four workers.", TRNG_MAX);
        log!("  and answering to yi26.local, so nobody has to know the number.");
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


async fn blink(led: &mut Output<'static>, half: Duration) {
    led.set_high();
    Timer::after(half).await;
    led.set_low();
    Timer::after(half).await;
}
