//! Enough DHCPv4 to be the server on a link with exactly one client.
//!
//! `embassy-net` ships a DHCP **client** and nothing else, and
//! [exp148](../../experiments/exp148-a-wire-with-no-address/) measured what that
//! leaves you with: a board and a host both waiting for somebody else to hand
//! out an address. On a laptop you can turn connection sharing on. On a phone
//! there is no such setting, and no way to add one.
//!
//! So the board answers. This crate is the half of that with no I/O in it —
//! given the bytes of a request it says what was asked, and given an answer it
//! writes the bytes. The socket lives in the firmware.
//!
//! # The whole protocol, for this case
//!
//! Four packets, and the client sends the first and third:
//!
//! ```text
//!   client ──DISCOVER──▶  "is anybody there?"        broadcast, it has no address
//!          ◀──OFFER────   "you may have 192.168.7.2"
//!          ──REQUEST──▶   "I'll take it"             still broadcast: not official yet
//!          ◀──ACK──────   "it's yours, for an hour"
//! ```
//!
//! Everything else DHCP can do — relays, multiple pools, declines, renewal
//! bookkeeping, conflict detection — exists because a real network has many
//! clients, several servers and a router between them. A USB cable has one
//! host on the other end of it. Building the general thing here would be
//! building a machine to teach a fact that fits in a diagram.
//!
//! # What it deliberately refuses
//!
//! Every one of these has been fed to it by a test, because a parser reached by
//! a network is reached by whatever the network feels like sending:
//!
//! - a packet shorter than the fixed header
//! - a packet with no magic cookie, or the wrong one
//! - an option whose length runs off the end of the buffer
//! - a packet with no message-type option at all
//! - a message type this server does not answer

#![no_std]
#![forbid(unsafe_code)]

// Only the tests allocate — `codes()` collects the option codes of a built
// reply so a test can say what is and is not in it.
#[cfg(test)]
extern crate alloc;

/// The fixed part of a DHCP message, before any options: `op` through `file`.
/// Everything up to here is at a known offset, which is why the parser can
/// check one length and then stop worrying.
pub const FIXED_LEN: usize = 236;

/// `0x63825363`, the four bytes that separate DHCP from the BOOTP it grew out
/// of. A packet without them is not a DHCP packet however plausible the rest
/// of it looks.
pub const MAGIC: [u8; 4] = [0x63, 0x82, 0x53, 0x63];

/// The smallest buffer `build_reply` will ever need. A reply is the fixed
/// header, the cookie, and at most five short options.
pub const REPLY_LEN: usize = FIXED_LEN + 4 + 32;

/// Ports. The server listens on 67 and answers to 68 — never the other way
/// round, which is the one thing that makes a DHCP conversation directional.
pub const SERVER_PORT: u16 = 67;
pub const CLIENT_PORT: u16 = 68;

const OP_REQUEST: u8 = 1;
const OP_REPLY: u8 = 2;
const HTYPE_ETHERNET: u8 = 1;
const HLEN_ETHERNET: u8 = 6;

const OPT_PAD: u8 = 0;
const OPT_SUBNET_MASK: u8 = 1;
const OPT_ROUTER: u8 = 3;
const OPT_REQUESTED_IP: u8 = 50;
const OPT_LEASE_TIME: u8 = 51;
const OPT_MESSAGE_TYPE: u8 = 53;
const OPT_SERVER_ID: u8 = 54;
const OPT_END: u8 = 255;

/// Offsets into the fixed header, named rather than counted at the call site.
mod at {
    pub const OP: usize = 0;
    pub const HTYPE: usize = 1;
    pub const HLEN: usize = 2;
    pub const XID: usize = 4;
    pub const FLAGS: usize = 10;
    pub const YIADDR: usize = 16;
    pub const SIADDR: usize = 20;
    pub const CHADDR: usize = 28;
}

/// The message types this server understands. Anything else parses fine and is
/// then not answered — which is different from being malformed, and the caller
/// gets to tell them apart.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MessageType {
    Discover,
    Request,
    /// Anything else with a well-formed option 53: DECLINE, RELEASE, INFORM,
    /// or a number nobody has defined. Carried rather than dropped so a log can
    /// say *what* arrived.
    Other(u8),
}

impl MessageType {
    fn from_byte(b: u8) -> Self {
        match b {
            1 => MessageType::Discover,
            3 => MessageType::Request,
            other => MessageType::Other(other),
        }
    }
}

/// What arrived, reduced to the four things a one-client server acts on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Request {
    pub kind: MessageType,
    /// The transaction ID. Copied into the reply verbatim: it is how the client
    /// knows an answer is to *its* question and not to somebody else's.
    pub xid: [u8; 4],
    /// The client's MAC, from `chaddr`. Only the first six bytes; the field is
    /// sixteen wide because DHCP predates the assumption that everything is
    /// Ethernet.
    pub chaddr: [u8; 6],
    /// Option 50, if present — "last time you gave me this one". A server with
    /// one address in its pool notes it and hands out that one address anyway.
    pub requested_ip: Option<[u8; 4]>,
}

/// Why a buffer was not a request. Each variant is a test.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Invalid {
    /// Shorter than the fixed header, or than the header plus the cookie.
    TooShort,
    /// Not `op = BOOTREQUEST`. A reply arriving on port 67 is somebody else's
    /// server talking, which is worth noticing rather than parsing.
    NotARequest,
    /// Not Ethernet, or an address length that is not six.
    NotEthernet,
    /// The four bytes after the fixed header were not `0x63825363`.
    NoMagicCookie,
    /// An option's length field ran past the end of the buffer. This is the
    /// one that matters: it is the shape of every buffer-overrun bug in every
    /// parser that trusts a length it was sent.
    TruncatedOption,
    /// Well-formed, but with no option 53. DHCP without a message type is
    /// BOOTP, and this is not a BOOTP server.
    NoMessageType,
}

/// Read a request out of a received datagram.
///
/// Everything this returns is copied out; the buffer is not borrowed, so the
/// caller can reuse it for the reply immediately.
pub fn parse(buf: &[u8]) -> Result<Request, Invalid> {
    if buf.len() < FIXED_LEN + MAGIC.len() {
        return Err(Invalid::TooShort);
    }
    if buf[at::OP] != OP_REQUEST {
        return Err(Invalid::NotARequest);
    }
    if buf[at::HTYPE] != HTYPE_ETHERNET || buf[at::HLEN] != HLEN_ETHERNET {
        return Err(Invalid::NotEthernet);
    }
    if buf[FIXED_LEN..FIXED_LEN + 4] != MAGIC {
        return Err(Invalid::NoMagicCookie);
    }

    let mut xid = [0u8; 4];
    xid.copy_from_slice(&buf[at::XID..at::XID + 4]);
    let mut chaddr = [0u8; 6];
    chaddr.copy_from_slice(&buf[at::CHADDR..at::CHADDR + 6]);

    let mut kind = None;
    let mut requested_ip = None;

    // The option walk. `i` only ever moves forward, and every step is bounds
    // checked against the buffer the caller gave us rather than against a
    // length the sender claimed.
    let mut i = FIXED_LEN + 4;
    while i < buf.len() {
        let code = buf[i];
        if code == OPT_END {
            break;
        }
        if code == OPT_PAD {
            i += 1;
            continue;
        }
        // A code with no length byte behind it is truncated, not empty.
        if i + 1 >= buf.len() {
            return Err(Invalid::TruncatedOption);
        }
        let len = buf[i + 1] as usize;
        let val = i + 2;
        if val + len > buf.len() {
            return Err(Invalid::TruncatedOption);
        }
        match code {
            OPT_MESSAGE_TYPE if len == 1 => kind = Some(MessageType::from_byte(buf[val])),
            OPT_REQUESTED_IP if len == 4 => {
                let mut ip = [0u8; 4];
                ip.copy_from_slice(&buf[val..val + 4]);
                requested_ip = Some(ip);
            }
            // Everything else is somebody else's business. A parameter request
            // list, a hostname, a vendor class — all fine, all skipped.
            _ => {}
        }
        i = val + len;
    }

    match kind {
        Some(kind) => Ok(Request {
            kind,
            xid,
            chaddr,
            requested_ip,
        }),
        None => Err(Invalid::NoMessageType),
    }
}

/// Which of the two answers to send.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reply {
    Offer,
    Ack,
}

impl Reply {
    fn code(self) -> u8 {
        match self {
            Reply::Offer => 2,
            Reply::Ack => 5,
        }
    }

    /// The reply a request calls for, or `None` if this server has nothing to
    /// say to it. Keeping the decision here means the firmware's socket loop
    /// contains no protocol knowledge at all.
    pub fn to(kind: MessageType) -> Option<Reply> {
        match kind {
            MessageType::Discover => Some(Reply::Offer),
            MessageType::Request => Some(Reply::Ack),
            MessageType::Other(_) => None,
        }
    }
}

/// What this server hands out. One address, because a USB cable has one host on
/// the other end of it.
#[derive(Debug, Clone, Copy)]
pub struct Lease {
    /// The address the client gets.
    pub client: [u8; 4],
    /// This server's own address — also option 54, which is how a client tells
    /// two servers apart on a network that has two.
    pub server: [u8; 4],
    pub mask: [u8; 4],
    pub seconds: u32,
    /// Option 3, the default gateway — and the one field here that is a
    /// **claim about the world** rather than a fact about this link.
    ///
    /// `None` is the honest answer for a board that is one end of a cable: it
    /// routes nothing, and a host told otherwise will act on it. exp149
    /// measured what `None` buys and what it may cost. A Pixel 9a took the
    /// address, kept its mobile data — and never showed the link as a network
    /// at all, which may be Android correctly declining to promote a network
    /// with no way out.
    ///
    /// So this is `Option`, and both answers are built, because the difference
    /// is a measurement rather than a preference. See exp150.
    pub router: Option<[u8; 4]>,
}

/// Write a reply into `out`, returning how many bytes to send.
///
/// `out` must be at least [`REPLY_LEN`]; anything shorter returns `None` rather
/// than writing a partial packet, because a truncated DHCP reply is worse than
/// no reply — the client waits out its timeout either way, and the truncated
/// one may be parsed first.
///
/// **No DNS, ever.** This board resolves nothing.
///
/// **A router option only if [`Lease::router`] asks for one.** The default is
/// none, because it is the honest answer — and exp150 builds both, because
/// exp149 found a phone that took the address and still never treated the link
/// as a network, which a missing gateway would explain.
pub fn build_reply(
    reply: Reply,
    req: &Request,
    lease: &Lease,
    out: &mut [u8],
) -> Option<usize> {
    if out.len() < REPLY_LEN {
        return None;
    }
    let n = FIXED_LEN + 4;
    out[..n].fill(0);

    out[at::OP] = OP_REPLY;
    out[at::HTYPE] = HTYPE_ETHERNET;
    out[at::HLEN] = HLEN_ETHERNET;
    out[at::XID..at::XID + 4].copy_from_slice(&req.xid);
    // The broadcast flag, set unconditionally. Every reply here goes to
    // 255.255.255.255 anyway — see the firmware for why — and this is the field
    // that tells the client to expect that.
    out[at::FLAGS] = 0x80;
    out[at::YIADDR..at::YIADDR + 4].copy_from_slice(&lease.client);
    out[at::SIADDR..at::SIADDR + 4].copy_from_slice(&lease.server);
    out[at::CHADDR..at::CHADDR + 6].copy_from_slice(&req.chaddr);
    out[FIXED_LEN..n].copy_from_slice(&MAGIC);

    let mut i = n;
    let mut put = |code: u8, val: &[u8], i: &mut usize| {
        out[*i] = code;
        out[*i + 1] = val.len() as u8;
        out[*i + 2..*i + 2 + val.len()].copy_from_slice(val);
        *i += 2 + val.len();
    };

    // Option 53 first, by convention and because it is what a client looks at
    // before it decides whether to read the rest.
    put(OPT_MESSAGE_TYPE, &[reply.code()], &mut i);
    put(OPT_SERVER_ID, &lease.server, &mut i);
    put(OPT_LEASE_TIME, &lease.seconds.to_be_bytes(), &mut i);
    put(OPT_SUBNET_MASK, &lease.mask, &mut i);
    if let Some(router) = lease.router {
        put(OPT_ROUTER, &router, &mut i);
    }
    out[i] = OPT_END;
    i += 1;

    Some(i)
}

#[cfg(test)]
mod tests {
    use super::*;

    const CHADDR: [u8; 6] = [0x02, 0x26, 0x00, 0x00, 0x03, 0x48];
    const XID: [u8; 4] = [0xde, 0xad, 0xbe, 0xef];

    const LEASE: Lease = Lease {
        client: [192, 168, 7, 2],
        server: [192, 168, 7, 1],
        mask: [255, 255, 255, 0],
        seconds: 3600,
        router: None,
    };

    /// A DISCOVER as a client would send it: fixed header, cookie, message
    /// type, a requested address, a parameter request list this server ignores.
    fn discover() -> [u8; 300] {
        let mut p = [0u8; 300];
        p[at::OP] = OP_REQUEST;
        p[at::HTYPE] = HTYPE_ETHERNET;
        p[at::HLEN] = HLEN_ETHERNET;
        p[at::XID..at::XID + 4].copy_from_slice(&XID);
        p[at::CHADDR..at::CHADDR + 6].copy_from_slice(&CHADDR);
        p[FIXED_LEN..FIXED_LEN + 4].copy_from_slice(&MAGIC);
        let mut i = FIXED_LEN + 4;
        for b in [OPT_MESSAGE_TYPE, 1, 1] {
            p[i] = b;
            i += 1;
        }
        for b in [OPT_REQUESTED_IP, 4, 192, 168, 7, 2] {
            p[i] = b;
            i += 1;
        }
        for b in [55u8, 4, 1, 3, 6, 51] {
            p[i] = b;
            i += 1;
        }
        p[i] = OPT_END;
        p
    }

    #[test]
    fn reads_a_discover() {
        let req = parse(&discover()).unwrap();
        assert_eq!(req.kind, MessageType::Discover);
        assert_eq!(req.xid, XID);
        assert_eq!(req.chaddr, CHADDR);
        assert_eq!(req.requested_ip, Some([192, 168, 7, 2]));
    }

    #[test]
    fn options_it_does_not_know_are_skipped_not_refused() {
        // Option 55 is in the fixture above and is none of this server's
        // business. Parsing has to walk past it to reach OPT_END, which is the
        // only reason the length byte of an unknown option matters at all.
        assert!(parse(&discover()).is_ok());
    }

    /// The test this crate exists for. A datagram arrives at whatever length
    /// the sender chose, and no length may panic, hang, or read past the end.
    ///
    /// exp136 made the same argument about a byte stream and cut it at every
    /// offset. A datagram cannot be cut in transit — but it can be *built*
    /// short by anything at all on the other end of the cable, and a parser
    /// that only ever sees well-formed packets in testing has not been tested.
    ///
    /// **A truncation is not the same thing as malformed**, and this test was
    /// written twice as if it were before the parser corrected it both times.
    /// DHCP options carry their own lengths and `OPT_END` is only needed when
    /// something follows it, so:
    ///
    /// > A cut **between** options leaves a smaller packet that is perfectly
    /// > valid. Only a cut **inside** one is malformed.
    ///
    /// That is the actual rule, it is not obvious, and encoding it is the
    /// difference between a parser that refuses real clients and one that
    /// reads past the end of a buffer. What has to hold at every length is
    /// then: nothing panics, nothing below one option parses, and a field that
    /// is not wholly present is reported absent rather than half-read.
    #[test]
    fn a_cut_between_options_is_valid_and_a_cut_inside_one_is_not() {
        let full = discover();
        for n in 0..=full.len() {
            if let Ok(req) = parse(&full[..n]) {
                // Whatever the length, a packet that parses reports what was
                // really in it. This is the assertion that would catch a parser
                // reading a field out of uninitialised or adjacent bytes.
                assert_eq!(req.xid, XID);
                assert_eq!(req.chaddr, CHADDR);
                assert_eq!(req.kind, MessageType::Discover);
            }
        }

        let cookie_end = FIXED_LEN + 4; // 240
        assert!(parse(&full[..cookie_end]).is_err(), "no options at all is not a request");
        for n in 0..cookie_end {
            assert!(parse(&full[..n]).is_err(), "{n} bytes cannot be a request");
        }

        // Option 53 occupies 240..243, option 50 occupies 243..249.
        assert_eq!(parse(&full[..243]).unwrap().requested_ip, None, "boundary: valid, shorter");
        for n in 244..249 {
            assert_eq!(
                parse(&full[..n]), Err(Invalid::TruncatedOption),
                "{n} bytes cuts through option 50"
            );
        }
        assert_eq!(parse(&full[..249]).unwrap().requested_ip, Some([192, 168, 7, 2]));
    }

    #[test]
    fn an_option_length_that_runs_off_the_end_is_refused() {
        let mut p = discover();
        // Claim 200 bytes of payload for the message-type option. Everything
        // before it is perfectly well-formed, which is the point: the packet
        // looks right until the byte that decides how far to read.
        p[FIXED_LEN + 5] = 200;
        assert_eq!(parse(&p), Err(Invalid::TruncatedOption));
    }

    #[test]
    fn a_code_with_no_length_byte_is_truncated_not_empty() {
        let mut p = [0u8; FIXED_LEN + 5];
        p[at::OP] = OP_REQUEST;
        p[at::HTYPE] = HTYPE_ETHERNET;
        p[at::HLEN] = HLEN_ETHERNET;
        p[FIXED_LEN..FIXED_LEN + 4].copy_from_slice(&MAGIC);
        p[FIXED_LEN + 4] = OPT_MESSAGE_TYPE; // and then the buffer ends
        assert_eq!(parse(&p), Err(Invalid::TruncatedOption));
    }

    #[test]
    fn the_cookie_is_checked() {
        let mut p = discover();
        p[FIXED_LEN] ^= 0xff;
        assert_eq!(parse(&p), Err(Invalid::NoMagicCookie));
    }

    #[test]
    fn a_reply_arriving_on_the_server_port_is_not_parsed_as_a_request() {
        let mut p = discover();
        p[at::OP] = OP_REPLY;
        assert_eq!(parse(&p), Err(Invalid::NotARequest));
    }

    #[test]
    fn bootp_without_a_message_type_is_not_ours() {
        let mut p = discover();
        // Overwrite the three bytes of option 53 with padding, leaving the
        // rest — so this is a well-formed packet that simply is not DHCP.
        for i in FIXED_LEN + 4..FIXED_LEN + 7 {
            p[i] = OPT_PAD;
        }
        assert_eq!(parse(&p), Err(Invalid::NoMessageType));
    }

    #[test]
    fn a_hardware_type_that_is_not_ethernet_is_refused() {
        let mut p = discover();
        p[at::HLEN] = 8;
        assert_eq!(parse(&p), Err(Invalid::NotEthernet));
    }

    #[test]
    fn discover_gets_an_offer_and_request_gets_an_ack() {
        assert_eq!(Reply::to(MessageType::Discover), Some(Reply::Offer));
        assert_eq!(Reply::to(MessageType::Request), Some(Reply::Ack));
        // RELEASE. Well-formed, and nothing this server needs to answer.
        assert_eq!(Reply::to(MessageType::Other(7)), None);
    }

    #[test]
    fn an_offer_is_the_bytes_a_client_expects() {
        let req = parse(&discover()).unwrap();
        let mut out = [0u8; REPLY_LEN];
        let n = build_reply(Reply::Offer, &req, &LEASE, &mut out).unwrap();

        assert_eq!(out[at::OP], OP_REPLY);
        assert_eq!(&out[at::XID..at::XID + 4], &XID, "xid is echoed verbatim");
        assert_eq!(&out[at::YIADDR..at::YIADDR + 4], &[192, 168, 7, 2]);
        assert_eq!(&out[at::CHADDR..at::CHADDR + 6], &CHADDR);
        assert_eq!(&out[FIXED_LEN..FIXED_LEN + 4], &MAGIC);
        assert_eq!(out[at::FLAGS], 0x80, "the reply says it is broadcast");

        assert_eq!(
            &out[FIXED_LEN + 4..n],
            &[
                OPT_MESSAGE_TYPE, 1, 2,
                OPT_SERVER_ID, 4, 192, 168, 7, 1,
                OPT_LEASE_TIME, 4, 0, 0, 0x0e, 0x10,
                OPT_SUBNET_MASK, 4, 255, 255, 255, 0,
                OPT_END,
            ]
        );
    }

    #[test]
    fn an_ack_differs_from_an_offer_in_exactly_one_byte() {
        let req = parse(&discover()).unwrap();
        let mut offer = [0u8; REPLY_LEN];
        let mut ack = [0u8; REPLY_LEN];
        let a = build_reply(Reply::Offer, &req, &LEASE, &mut offer).unwrap();
        let b = build_reply(Reply::Ack, &req, &LEASE, &mut ack).unwrap();
        assert_eq!(a, b);
        let differ: usize = (0..a).filter(|&i| offer[i] != ack[i]).count();
        assert_eq!(differ, 1, "only the message type changes");
    }

    /// Walk the options of a built reply and return the ones present.
    fn codes(out: &[u8], n: usize) -> alloc::vec::Vec<u8> {
        let mut v = alloc::vec::Vec::new();
        let mut i = FIXED_LEN + 4;
        while i < n && out[i] != OPT_END {
            v.push(out[i]);
            i += 2 + out[i + 1] as usize;
        }
        v
    }

    #[test]
    fn no_router_is_the_default_and_it_is_a_decision_not_an_omission() {
        let req = parse(&discover()).unwrap();
        let mut out = [0u8; REPLY_LEN];
        let n = build_reply(Reply::Ack, &req, &LEASE, &mut out).unwrap();
        assert!(!codes(&out, n).contains(&OPT_ROUTER));
        // And never DNS, under any configuration — there is no field for it.
        assert!(!codes(&out, n).contains(&6));
    }

    #[test]
    fn a_router_is_offered_when_the_lease_names_one() {
        let req = parse(&discover()).unwrap();
        let mut out = [0u8; REPLY_LEN];
        let lease = Lease { router: Some([192, 168, 7, 1]), ..LEASE };
        let n = build_reply(Reply::Ack, &req, &lease, &mut out).unwrap();
        assert!(codes(&out, n).contains(&OPT_ROUTER));
        // Six bytes: code, length, four octets. The whole difference between
        // the two builds exp150 ships.
        let mut plain = [0u8; REPLY_LEN];
        let m = build_reply(Reply::Ack, &req, &LEASE, &mut plain).unwrap();
        assert_eq!(n - m, 6);
    }

    #[test]
    fn a_router_still_fits_the_smallest_buffer_build_reply_promises() {
        let req = parse(&discover()).unwrap();
        let lease = Lease { router: Some([192, 168, 7, 1]), ..LEASE };
        let mut out = [0u8; REPLY_LEN];
        assert!(build_reply(Reply::Ack, &req, &lease, &mut out).is_some());
    }

    #[test]
    fn a_buffer_too_small_writes_nothing_rather_than_something_partial() {
        let req = parse(&discover()).unwrap();
        let mut out = [0xAAu8; REPLY_LEN - 1];
        assert!(build_reply(Reply::Ack, &req, &LEASE, &mut out).is_none());
        assert!(out.iter().all(|&b| b == 0xAA), "nothing was written");
    }
}
