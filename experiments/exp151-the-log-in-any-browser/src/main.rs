//! exp151 — the log, in any browser.
//!
//! Everything this repository debugs with reaches the board over **CDC**, and
//! reaching CDC from a browser means WebUSB. That is Chromium-only: no iPhone
//! has it, and neither does Firefox or Safari on Android. For a student whose
//! only computer is one of those phones, this repository has been unusable
//! from the first experiment that printed anything.
//!
//! [exp150](../../exp150-a-page-served-by-the-board/) found the way round it
//! and did not take it. A board that serves HTTP can be read by *any* browser
//! — but exp150 served a status page, and deliberately not the log, because
//! serving the log means giving [`usb-log`](../../../crates/usb-log/) a second
//! consumer and that crate is the one instrument everything here is debugged
//! with. This experiment does it, carefully.
//!
//! # What changes, and what does not
//!
//! `usb-log` gains a `retain` feature: the most recent lines are also kept in a
//! ring that something else can read. **With the feature off it compiles to
//! exactly what it compiled to before**, and the queue that goes to the serial
//! port is untouched either way — it still forgets each line as it sends it,
//! which is the whole reason it never stalls the thing being logged.
//!
//! The two consumers have opposite rules, and that is the point:
//!
//! ```text
//!   the queue    drops the NEWEST when full   — the reader is already there
//!   the ring     drops the OLDEST when full   — the reader arrives late
//! ```
//!
//! Somebody who opens a page two minutes after plugging the board in wants what
//! just happened. Somebody watching a serial port wants not to miss the next
//! thing. Neither policy is right for both, so there are two.
//! [`crates/log-ring`](../../../crates/log-ring/) decides which lines survive
//! and has no I/O in it, so `cargo test` can wrap it a thousand times on a
//! machine with no board.
//!
//! # Why there is only one role here
//!
//! exp150 measured that a phone's browser reaches the board **only when the
//! phone is the one that handed out the address** — Android's Ethernet
//! tethering, with the board as a DHCP client. A board that assigns itself an
//! address is unreachable from the browser it is trying to serve. So this
//! firmware has no server role at all: it asks.
//!
//! # And a name, which is the other half
//!
//! Serving the log is useless to somebody without WebUSB if *finding* the board
//! needs WebUSB — and until this experiment it did: the address was read out of
//! the log over CDC. So the board answers to **`yi26.local`**.
//!
//! Android has resolved `.local` since 2021 by sending an ordinary DNS query to
//! `224.0.0.251:5353` and waiting for a reply — RFC 6762 §5.1, "one-shot
//! multicast DNS" — and Chrome's address bar goes through that resolver from
//! Android 12 on. So the responder needed here is small: receive, check the
//! question is for us, answer whoever asked. No probing, no announcements, no
//! service discovery, no caching. All of those exist because a real network has
//! many responders; a USB cable has one host on the other end.
//!
//! The protocol is in [`mdns`](../../../crates/mdns/) with no socket in it, and
//! it refuses more than it accepts — including compression pointers, which are
//! legal DNS and are where parsers grow loops that read their own tails.
//!
//! # Measured on a Pixel 9a, 2026-08-05: one half works and one half does not
//!
//! **The log renders in Chrome on the phone**, at the address the phone handed
//! out, refreshing itself, with no toolchain and no permission dialog. That is
//! the claim this experiment was built for and it holds.
//!
//! **The name does not resolve.** `yi26.local` returns
//! `DNS_PROBE_FINISHED_NXDOMAIN`, and the board's own log says why it is not
//! its fault:
//!
//! ```text
//! mdns: listening as yi26.local
//! mdns: 318 bytes ignored: NotAQuery
//! mdns: 318 bytes ignored: NotAQuery
//! ```
//!
//! Multicast **does** reach the board — those are mDNS *responses*, something
//! on the phone announcing its own services on that link. So the group was
//! joined, the socket is live, and the phone participates. What never arrived
//! is a **question** for `yi26.local`. Chrome asked something, was told there
//! is no such name, and the board was not the one it asked.
//!
//! The likely reason is the one that has shadowed this whole road: Android
//! resolves names on the **default network**, and a tethered link is a
//! downstream. That is a guess about a mechanism; what is measured is that a
//! correct responder, verified answering on Ubuntu, is unreachable from the
//! browser on the other end of its own cable.
//!
//! So the name half is a **negative result**, and it is worth as much as a
//! positive one: an implementation can be right, tested, and running, and still
//! be useless because of a routing decision made somewhere else entirely.

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
use usb_log::{log, log_transient};

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
    TRNG_IRQ => TrngInterruptHandler<TRNG>;
});

const PACKET: usize = 64;
const MTU: usize = 1514;

const HOST_MAC: [u8; 6] = [0x02, 0x26, 0x00, 0x00, 0x01, 0x51];
const OUR_MAC: [u8; 6] = [0x02, 0x26, 0x00, 0x00, 0x02, 0x51];

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

/// The page: the retained log, and a `<meta refresh>` so it updates itself.
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
        "<!doctype html><meta charset=utf-8>\
<meta name=viewport content=\"width=device-width,initial-scale=1\">\
<meta http-equiv=refresh content=3>\
<title>{}.{}.{}.{} &mdash; the board's log</title>\
<style>body{{font:14px/1.5 ui-monospace,monospace;margin:0;padding:1rem;background:#111;color:#ddd}}\
h1{{font:600 15px/1.4 system-ui,sans-serif;margin:0 0 .3rem}}\
p{{font:12px/1.5 system-ui,sans-serif;color:#888;margin:0 0 1rem}}\
pre{{white-space:pre-wrap;word-break:break-all;margin:0}}</style>\
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
    page: &'static mut [u8],
) -> ! {
    let mut discard = [0u8; 512];
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

        // Read whatever the client sends until it pauses. We need to consume
        // the request so the socket is not closed underneath an unsent one.
        match socket.read(&mut discard).await {
            Ok(0) | Err(_) => {
                socket.abort();
                continue;
            }
            Ok(n) => log_transient!("http: {} bytes of request, discarded", n),
        }

        let served = SERVED.fetch_add(1, Ordering::Relaxed) + 1;
        let len = render(page, my_address(stack).unwrap_or([0; 4]));
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
        // route to this board can now read this page. What is on it is a chip
        // ID, an uptime and a counter. On a board that served anything worth
        // keeping, this line would be the wrong trade.
        //
        // `Allow-Private-Network` is Chrome's Private Network Access check: a
        // page on a secure origin fetching a private address is preflighted,
        // and without this the preflight fails before the request is made. It
        // is sent on every response because this server answers every method
        // the same way, preflight included.
        let _ = write!(
            head,
            "HTTP/1.0 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\
Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Private-Network: true\r\n\
Content-Length: {}\r\nConnection: close\r\n\r\n",
            len
        );

        let ok = socket.write_all(head.as_bytes()).await.is_ok()
            && socket.write_all(&page[..len]).await.is_ok()
            && socket.flush().await.is_ok();
        if ok {
            log_transient!("http: served request #{} ({} bytes)", served, len);
        } else {
            log_transient!("http: request #{} was not delivered", served);
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
    config.product = Some("exp151 the log in any browser");
    config.serial_number = Some("151");
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

    log!("exp151 up. The log goes to CDC *and* to anyone who asks over HTTP.");

        // The client role cannot print its address here: it does not have one yet,
    // and will not for a few hundred milliseconds. The reporter prints it once
    // it arrives, and keeps printing it — because the line somebody is going to
    // read off `log.html` and type into a browser must not have scrolled away
    // by the time they look.
    {
        log!("  asking for an address — whoever is on the other end is the server here.");
        log!("  serving the log itself on port {}, at whatever address I am given.", HTTP_PORT);
        log!("  and answering to yi26.local, so nobody has to know the number.");
        log!("  I also tell the DHCP server my name — some of them make that resolvable.");
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
