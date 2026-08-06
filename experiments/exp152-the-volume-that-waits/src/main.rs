//! exp152 — the volume that waits.
//!
//! [exp151](../../exp151-the-log-in-any-browser/) put the board's log in any
//! browser and left one thing standing: **finding the board still needed
//! WebUSB**, because the address was read out of the log over CDC. A name did
//! not fix it — a Pixel 9a returns `NXDOMAIN` for `yi26.local`, and the board's
//! own log shows the question never arrives.
//!
//! So the board carries the answer on a disk of its own. Plug it in, wait for
//! the LED, open the drive that appears in the Files app, tap one file. No
//! WebUSB, no typing, no bookmark, and nothing to download first.
//!
//! # Why this was thought impossible, and why it is not
//!
//! [exp137](../../exp137-the-volume-that-changes/) measured that a host serving
//! a **mounted** volume answers file reads out of its own cache: the bytes
//! moved on the device and the host showed the old ones. An address that
//! arrives ten seconds after the drive appears would therefore be written into
//! a file nobody ever sees.
//!
//! That conclusion was applied too widely, and the person running these
//! experiments said so. exp137 also measured the other half:
//!
//! > **a fresh mount reads the new volume — the bytes really moved**
//!
//! A volume that has never been mounted has no cache to answer from. So this
//! firmware does not change a mounted disk. It reports **no medium at all**
//! until it knows its address, and only then does the disk exist. What the host
//! does then is a first mount, which is the case exp137 found working.
//!
//! # What is on it
//!
//! One page whose only job is a link, one text file with the address in it for
//! anybody who would rather read it, and a README. Written once, when the
//! address is known, and never rewritten — so there is no second version for a
//! cache to be stale about.
//!
//! The address is **not** in the filename. An IPv4 address is up to fifteen
//! characters and FAT12's 8.3 names hold eight; the volume label holds eleven.
//! Neither fits, and contorting the address to fit would have made the one
//! thing a person reads harder to read.

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
use embassy_rp::usb::{Driver, Endpoint, InterruptHandler};
use embassy_usb::driver::{Endpoint as _, EndpointIn, EndpointOut};
use embassy_rp::usb::{In, Out};
use embedded_io_async::Write as _;
use core::fmt::Write as _;
use core::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use embassy_time::{with_timeout, Duration, Instant, Timer};
use embassy_usb::class::cdc_acm::{CdcAcmClass, ControlChanged, Receiver, Sender, State as AcmState};
use embassy_usb::class::cdc_ncm::embassy_net::{Device, Runner as NcmRunner, State as NetDeviceState};
use embassy_usb::class::cdc_ncm::{CdcNcmClass, State as NcmState};
use embassy_usb::{Builder, Config as UsbConfig, UsbDevice};
use panic_halt as _;
use rp2350_linker as _;
use static_cell::StaticCell;
use usb_log::{log, log_transient};

/// The volume does not exist until this is true. Everything the host asks
/// about the medium is refused until then — see `storage_task`.
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

const HOST_MAC: [u8; 6] = [0x02, 0x26, 0x00, 0x00, 0x01, 0x52];
const OUR_MAC: [u8; 6] = [0x02, 0x26, 0x00, 0x00, 0x02, 0x52];

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
            PENDING_VOLUME.put(pinned);
            stack.set_config_v4(ConfigV4::Static(StaticConfigV4 {
                address: Ipv4Cidr::new(
                    Ipv4Address::new(pinned[0], pinned[1], pinned[2], pinned[3]),
                    prefix,
                ),
                gateway: cfg.gateway,
                dns_servers: cfg.dns_servers,
            }));
        }
        None => {
            log!(
                "pinning: /{} leaves no room for host {} — keeping the leased address",
                prefix, PINNED_HOST
            );
            PENDING_VOLUME.put(got);
        }
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
                (true, false) => log!(
                    "{} ms  link UP, still asking. TURN ON Ethernet tethering — \
Settings > Network & internet > Hotspot & tethering. Nothing appears until you do.",
                    ms
                ),
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
    config.product = Some("exp152 the volume that waits");
    config.serial_number = Some("152");
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

    // The fifth interface — **the fifth, not the fifth and sixth**. CDC is two,
    // NCM is two, and a mass-storage function is ONE interface carrying two
    // endpoints. That makes five, which is what `lsusb` reports and what
    // exp155 measured when this arithmetic was questioned. This comment said
    // "fifth and sixth" for three experiments; two endpoints were counted as
    // two interfaces. It is still the most complex composite here and still the
    // reason `max-interface-count-8` is set rather than inherited.
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

    log!("exp152 up. A log over HTTP, and a disk that waits until it can point at it.");

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
const INQUIRY_PRODUCT: &[u8; 16] = b"exp152 waiting  ";

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
/// went to Google — so the address has to be tappable rather than typable. A
/// link is a top-level navigation, which is the one thing exp150 measured going
/// through from a `content://` page.
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
<h1>Open the board</h1>\
<p>This drive came off the board, and so did the address below. Tap it &mdash; \
do not type it, because a phone's address bar will search for it instead.</p>\
<a href=\"http://{}.{}.{}.{}/\">http://{}.{}.{}.{}/</a>\
<p>That page is the board's own log, refreshing itself. No WebUSB, no \
permission dialog, nothing installed.</p>",
        addr[0], addr[1], addr[2], addr[3], addr[0], addr[1], addr[2], addr[3]
    );
    let page_len = w.n;
    // A `Cursor` truncates silently — that is its bargain, and it is the right
    // one for a log line. For a page it is a trap, and this firmware fell into
    // it: at 640 bytes the buffer filled exactly, the link's `href` survived
    // because it comes first, and the text after it was cut mid-address. The
    // phone showed a working button labelled `http://10`.
    //
    // The evidence was on screen the whole time — a directory listing saying
    // `OPEN.HTM  640`, against a buffer declared as 640. A buffer that
    // truncates in silence needs something that breaks the silence.
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

const README: &[u8] = b"exp152 - the drive that waited until it had something to say.\r\n\r\nTHE ORDER MATTERS. This drive did not exist until the phone gave the board\r\nan address, and the phone will not do that until you turn ON Ethernet\r\ntethering - which is greyed out until something is plugged in. So:\r\n\r\n  1. plug the board in\r\n  2. turn on Ethernet tethering, straight away\r\n  3. wait for the LED to blink fast; this drive appears then\r\n\r\nLeaving a long gap at step 2 is what goes wrong. The board keeps asking\r\nforever, but a host that has been told 'no medium' for long enough may\r\nstop looking.\r\n\r\nThis volume did not exist when you plugged the board in. It appeared once\r\nthe board had been given an address, because a disk that is mounted before\r\nit knows the answer is a disk whose file the host will serve you out of its\r\nown cache - which exp137 measured, on a different host, a month earlier.\r\n\r\nOPEN.HTM   tap the link. It goes to this board's own log.\r\nADDRESS.TXT  the same address as plain text, if you would rather read it.\r\n\r\nThe phone must be sharing its connection: Settings > Network & internet >\r\nHotspot & tethering > Ethernet tethering. That switch is greyed out until\r\na device is attached.\r\n";
