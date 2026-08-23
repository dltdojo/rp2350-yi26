// SPDX-License-Identifier: Apache-2.0
//! CTAPHID to *application* firmware, and the one question worth asking over it.
//!
//! Every other transport in this tool talks to the bootrom (`picoboot`) or to a
//! serial port (`board`). This one talks to a running security key, over the
//! HID interface exp168 built by hand, and asks it `authenticatorGetInfo` — the
//! device's own description of what it can do.
//!
//! # Why this is in the tool and the client in exp168 is not
//!
//! [`docs/tool-needs.md`](../../../docs/tool-needs.md) has the rule: a gap
//! becomes a command when it recurred **and** the reach is not itself the
//! lesson. Hand-writing CTAPHID *is* exp168's lesson, and exp169 to exp172 keep
//! their own `ctaphid.py` for that reason. From exp173 the client stopped being
//! the subject — that experiment deliberately handed the job to `libfido2` —
//! and by exp177 the reach had turned into one experiment importing another
//! experiment's script across directories, because `fido2-token -I` prints an
//! algorithm it cannot name as `unknown` and a ruling was nearly made on it.
//!
//! So this reports **numbers, not names it happens to know**: an unrecognised
//! COSE algorithm comes out as its identifier, and an unrecognised `getInfo`
//! field comes out in `other_fields` rather than being dropped. A tool that
//! silently omits what it does not understand is the thing this replaces.
//!
//! # What it does not do
//!
//! No `makeCredential`, no `getAssertion`, no PIN. Reading a device's
//! self-description changes nothing on it; the rest are operations with
//! consequences, and belong to the experiments that are about them.

use std::io::{Read, Write};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use cbor::{Item, ReadError, Reader};

const PACKET: usize = 64;
/// An initialisation packet carries `CID(4) + CMD(1) + BCNT(2)` and 57 bytes of
/// payload; each continuation carries `CID(4) + SEQ(1)` and 59. exp128's
/// arithmetic, and the reason a `getInfo` reply needs reassembling.
const INIT_PAYLOAD: usize = PACKET - 7;
const CONT_PAYLOAD: usize = PACKET - 5;

const BROADCAST: [u8; 4] = [0xff, 0xff, 0xff, 0xff];
const CTAPHID_INIT: u8 = 0x06;
const CTAPHID_CBOR: u8 = 0x10;
const CTAPHID_ERROR: u8 = 0x3f;
/// The packet exp174 is about: "still here", sent while the device thinks. A
/// client that treats the first reply as the answer reads its one payload byte
/// as a CTAP status and reports an error the device never sent — which is
/// exactly what happened in exp177 before this was written down.
const CTAPHID_KEEPALIVE: u8 = 0x3b;

pub const AUTHENTICATOR_GET_INFO: u8 = 0x04;

/// Usage Page (`0xF1D0`), Usage (`0x01`) — the two report-descriptor items that
/// make a HID device a FIDO authenticator to every host tool there is, and
/// (measured in exp168) what earns the logged-in user access without a udev
/// rule of this repository's own.
const FIDO_USAGE: [u8; 5] = [0x06, 0xd0, 0xf1, 0x09, 0x01];

/// COSE algorithm identifiers, from the IANA registry.
///
/// Deliberately short. Anything absent is reported as its number, because
/// "unknown" is what this command exists to stop happening.
const COSE: &[(i64, &str)] = &[
    (-7, "ES256"),
    (-8, "EdDSA"),
    (-35, "ES384"),
    (-36, "ES512"),
    (-37, "PS256"),
    (-47, "ES256K"),
    (-257, "RS256"),
];

fn cose_name(alg: i64) -> Option<&'static str> {
    COSE.iter().find(|(a, _)| *a == alg).map(|(_, n)| *n)
}

pub struct Found {
    pub path: String,
    pub name: String,
}

/// Every hidraw node whose report descriptor says FIDO.
///
/// The same way libfido2 finds one, and the same way exp173's client does: by
/// asking each node what it claims to be, not by matching vendor IDs. A board
/// running this repository's firmware and a commercial key are found alike.
pub fn find() -> Vec<Found> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir("/sys/class/hidraw") else {
        return out;
    };
    let mut names: Vec<String> = entries
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.starts_with("hidraw"))
        .collect();
    names.sort();
    for node in names {
        let desc = format!("/sys/class/hidraw/{node}/device/report_descriptor");
        let Ok(bytes) = std::fs::read(&desc) else {
            continue;
        };
        if !bytes.starts_with(&FIDO_USAGE) {
            continue;
        }
        let name = std::fs::read_to_string(format!("/sys/class/hidraw/{node}/device/uevent"))
            .ok()
            .and_then(|u| {
                u.lines()
                    .find_map(|l| l.strip_prefix("HID_NAME=").map(str::to_string))
            })
            .unwrap_or_else(|| "unnamed".to_string());
        out.push(Found {
            path: format!("/dev/{node}"),
            name,
        });
    }
    out
}

pub struct Link {
    file: std::fs::File,
    rx: mpsc::Receiver<[u8; PACKET]>,
}

impl Link {
    pub fn open(path: &str) -> Result<Self, String> {
        let file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(path)
            .map_err(|e| format!("cannot open {path}: {e}"))?;
        let reading = file
            .try_clone()
            .map_err(|e| format!("cannot clone the handle to {path}: {e}"))?;

        // A reader thread and a channel, rather than a non-blocking fd. `read`
        // on hidraw blocks until a report arrives, and there is no timeout in
        // `std` for it; the alternative is a libc dependency for one flag. The
        // thread is left blocked in `read` when this returns — acceptable
        // precisely because this is a short-lived command that then exits, and
        // stated here so that nobody reuses it in something long-lived.
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let mut reading = reading;
            loop {
                let mut buf = [0u8; PACKET];
                match reading.read(&mut buf) {
                    Ok(n) if n > 0 => {
                        if tx.send(buf).is_err() {
                            return;
                        }
                    }
                    Ok(_) => return,
                    Err(_) => return,
                }
            }
        });
        Ok(Link { file, rx })
    }

    fn send_packet(&mut self, pkt: &[u8; PACKET]) -> Result<(), String> {
        // Linux hidraw wants the report number first. These devices use no
        // numbered reports, so it is zero — and leaving it out is a write that
        // succeeds and delivers 63 bytes of the wrong thing.
        let mut framed = [0u8; PACKET + 1];
        framed[1..].copy_from_slice(pkt);
        self.file
            .write_all(&framed)
            .map_err(|e| format!("write failed: {e}"))
    }

    fn read_packet(&self, timeout: Duration) -> Option<[u8; PACKET]> {
        self.rx.recv_timeout(timeout).ok()
    }

    fn send_message(&mut self, cid: [u8; 4], cmd: u8, payload: &[u8]) -> Result<(), String> {
        let first = payload.len().min(INIT_PAYLOAD);
        let mut pkt = [0u8; PACKET];
        pkt[0..4].copy_from_slice(&cid);
        pkt[4] = 0x80 | cmd;
        pkt[5..7].copy_from_slice(&(payload.len() as u16).to_be_bytes());
        pkt[7..7 + first].copy_from_slice(&payload[..first]);
        self.send_packet(&pkt)?;

        let mut sent = first;
        let mut seq = 0u8;
        while sent < payload.len() {
            let n = (payload.len() - sent).min(CONT_PAYLOAD);
            let mut cont = [0u8; PACKET];
            cont[0..4].copy_from_slice(&cid);
            cont[4] = seq;
            cont[5..5 + n].copy_from_slice(&payload[sent..sent + n]);
            self.send_packet(&cont)?;
            sent += n;
            seq = seq.wrapping_add(1);
        }
        Ok(())
    }

    /// Reads one whole message, skipping keepalives and counting them.
    fn read_message(&self, deadline: Duration) -> Result<(u8, Vec<u8>, u32), String> {
        let start = Instant::now();
        let mut keepalives = 0u32;
        loop {
            let left = deadline
                .checked_sub(start.elapsed())
                .ok_or_else(|| "the device stopped answering".to_string())?;
            let head = self
                .read_packet(left)
                .ok_or_else(|| "the device stopped answering".to_string())?;
            let cmd = head[4] & 0x7f;
            let bcnt = u16::from_be_bytes([head[5], head[6]]) as usize;
            if cmd == CTAPHID_KEEPALIVE {
                keepalives += 1;
                continue;
            }
            let mut body: Vec<u8> = head[7..].to_vec();
            while body.len() < bcnt {
                let left = deadline
                    .checked_sub(start.elapsed())
                    .ok_or_else(|| "a message stopped half way".to_string())?;
                let cont = self
                    .read_packet(left)
                    .ok_or_else(|| "a message stopped half way".to_string())?;
                body.extend_from_slice(&cont[5..]);
            }
            body.truncate(bcnt);
            return Ok((cmd, body, keepalives));
        }
    }

    /// `CTAPHID_INIT` on the broadcast channel: returns the allocated channel,
    /// the protocol version and the capability byte.
    pub fn init(&mut self) -> Result<([u8; 4], u8, u8), String> {
        // Drain anything a previous exchange left behind. A stale keepalive
        // read as an INIT reply is a channel ID made of somebody else's bytes.
        while self.read_packet(Duration::from_millis(50)).is_some() {}

        let nonce = [1u8, 2, 3, 4, 5, 6, 7, 8];
        self.send_message(BROADCAST, CTAPHID_INIT, &nonce)?;
        let (cmd, body, _) = self.read_message(Duration::from_secs(2))?;
        if cmd == CTAPHID_ERROR {
            return Err(format!("CTAPHID error 0x{:02x} to INIT", body.first().copied().unwrap_or(0)));
        }
        if body.len() < 17 {
            return Err(format!("INIT reply is {} bytes, expected 17", body.len()));
        }
        if body[..8] != nonce {
            return Err("INIT reply echoed a different nonce — another client is talking to this device".to_string());
        }
        Ok((
            [body[8], body[9], body[10], body[11]],
            body[12],
            body[16],
        ))
    }

    /// One CBOR command. Returns the status byte, the payload after it, and how
    /// many keepalives arrived first.
    pub fn cbor(&mut self, cid: [u8; 4], payload: &[u8]) -> Result<(u8, Vec<u8>, u32), String> {
        self.send_message(cid, CTAPHID_CBOR, payload)?;
        let (cmd, body, keepalives) = self.read_message(Duration::from_secs(30))?;
        if cmd == CTAPHID_ERROR {
            return Err(format!(
                "CTAPHID error 0x{:02x} — the transport refused before CTAP saw it",
                body.first().copied().unwrap_or(0)
            ));
        }
        let Some((status, rest)) = body.split_first() else {
            return Err("an empty CBOR reply".to_string());
        };
        Ok((*status, rest.to_vec(), keepalives))
    }
}

/// What `authenticatorGetInfo` said, in the fields CTAP 2.1 numbers.
#[derive(Default)]
pub struct Info {
    pub versions: Vec<String>,
    pub extensions: Vec<String>,
    pub aaguid: Option<String>,
    pub options: Vec<(String, bool)>,
    pub max_msg_size: Option<u64>,
    pub pin_protocols: Vec<u64>,
    pub max_cred_count_in_list: Option<u64>,
    pub max_cred_id_length: Option<u64>,
    pub transports: Vec<String>,
    /// `(identifier, name-or-empty, credential type)`.
    pub algorithms: Vec<(i64, String, String)>,
    pub firmware_version: Option<u64>,
    /// Keys that are present and not interpreted here. Reported rather than
    /// dropped: a field this tool does not know is still a field the device
    /// sent, and hiding it is how `unknown` happens.
    pub other_fields: Vec<u64>,
    /// What was wrong, when the device's bytes are valid CBOR that CTAP2 does
    /// not permit. Reported and not refused, because a diagnostic that will not
    /// speak to a sloppy device is a diagnostic you cannot use on the day you
    /// need it. `None` means nothing was wrong.
    pub non_canonical: Option<String>,
}

fn text_key_order(prev: &str, next: &str) -> bool {
    // CTAP2's canonical order for text keys: shorter first, then bytewise.
    (prev.len(), prev.as_bytes()) < (next.len(), next.as_bytes())
}

fn strings(rd: &mut Reader<'_>) -> Result<Vec<String>, ReadError> {
    let n = match rd.next()? {
        Item::Array(n) => n,
        _ => return Err(ReadError::Unsupported),
    };
    let mut out = Vec::new();
    for _ in 0..n {
        match rd.next()? {
            Item::Text(s) => out.push(s.to_string()),
            _ => return Err(ReadError::Unsupported),
        }
    }
    Ok(out)
}

fn uints(rd: &mut Reader<'_>) -> Result<Vec<u64>, ReadError> {
    let n = match rd.next()? {
        Item::Array(n) => n,
        _ => return Err(ReadError::Unsupported),
    };
    let mut out = Vec::new();
    for _ in 0..n {
        match rd.next()? {
            Item::Uint(v) => out.push(v),
            _ => return Err(ReadError::Unsupported),
        }
    }
    Ok(out)
}

pub fn parse_get_info(bytes: &[u8]) -> Result<Info, String> {
    let mut info = Info::default();
    let mut rd = Reader::new(bytes);
    let pairs = match rd.next() {
        Ok(Item::Map(n)) => n,
        Ok(_) => return Err("getInfo did not answer with a map".to_string()),
        Err(e) => return Err(format!("getInfo is not readable CBOR: {e:?}")),
    };

    let mut last_key: Option<u64> = None;
    for _ in 0..pairs {
        let key = match rd.next() {
            Ok(Item::Uint(k)) => k,
            Ok(_) => return Err("a getInfo key that is not an unsigned integer".to_string()),
            Err(e) => return Err(format!("getInfo stopped being readable: {e:?}")),
        };
        if let Some(prev) = last_key {
            if key <= prev && info.non_canonical.is_none() {
                info.non_canonical = Some(format!("map key {key} does not follow {prev}"));
            }
        }
        last_key = Some(key);

        let read = (|| -> Result<(), ReadError> {
            match key {
                1 => info.versions = strings(&mut rd)?,
                2 => info.extensions = strings(&mut rd)?,
                3 => match rd.next()? {
                    Item::Bytes(b) => {
                        info.aaguid = Some(b.iter().map(|x| format!("{x:02x}")).collect())
                    }
                    _ => return Err(ReadError::Unsupported),
                },
                4 => {
                    let n = match rd.next()? {
                        Item::Map(n) => n,
                        _ => return Err(ReadError::Unsupported),
                    };
                    let mut prev: Option<String> = None;
                    for _ in 0..n {
                        let name = match rd.next()? {
                            Item::Text(s) => s.to_string(),
                            _ => return Err(ReadError::Unsupported),
                        };
                        if let Some(p) = &prev {
                            if !text_key_order(p, &name) && info.non_canonical.is_none() {
                                info.non_canonical =
                                    Some(format!("option {name:?} does not follow {p:?}"));
                            }
                        }
                        prev = Some(name.clone());
                        let value = match rd.next()? {
                            Item::Bool(v) => v,
                            _ => return Err(ReadError::Unsupported),
                        };
                        info.options.push((name, value));
                    }
                }
                5 => info.max_msg_size = Some(uint(&mut rd)?),
                6 => info.pin_protocols = uints(&mut rd)?,
                7 => info.max_cred_count_in_list = Some(uint(&mut rd)?),
                8 => info.max_cred_id_length = Some(uint(&mut rd)?),
                9 => info.transports = strings(&mut rd)?,
                10 => {
                    let n = match rd.next()? {
                        Item::Array(n) => n,
                        _ => return Err(ReadError::Unsupported),
                    };
                    for _ in 0..n {
                        let fields = match rd.next()? {
                            Item::Map(n) => n,
                            _ => return Err(ReadError::Unsupported),
                        };
                        let (mut alg, mut kind) = (None, String::new());
                        for _ in 0..fields {
                            let name = match rd.next()? {
                                Item::Text(s) => s.to_string(),
                                _ => return Err(ReadError::Unsupported),
                            };
                            match (name.as_str(), rd.next()?) {
                                ("alg", Item::Nint(v)) => alg = Some(v),
                                ("alg", Item::Uint(v)) => alg = Some(v as i64),
                                ("type", Item::Text(s)) => kind = s.to_string(),
                                _ => {}
                            }
                        }
                        if let Some(a) = alg {
                            info.algorithms.push((
                                a,
                                cose_name(a).unwrap_or("").to_string(),
                                kind,
                            ));
                        }
                    }
                }
                14 => info.firmware_version = Some(uint(&mut rd)?),
                other => {
                    info.other_fields.push(other);
                    rd.skip()?;
                }
            }
            Ok(())
        })();
        if let Err(e) = read {
            return Err(format!("getInfo field {key} is not what CTAP 2.1 says: {e:?}"));
        }
    }

    if !rd.is_empty() {
        info.non_canonical = Some(format!(
            "{} bytes left over after the map",
            bytes.len() - rd.position()
        ));
    }
    Ok(info)
}

fn uint(rd: &mut Reader<'_>) -> Result<u64, ReadError> {
    match rd.next()? {
        Item::Uint(v) => Ok(v),
        _ => Err(ReadError::Unsupported),
    }
}

/// `wink`, `cbor`, `msg` — and note that bit 3 is `nmsg`, so a device that
/// supports CTAP1 messages is one with the bit *clear*.
pub fn capability_names(caps: u8) -> Vec<&'static str> {
    let mut out = Vec::new();
    if caps & 0x01 != 0 {
        out.push("wink");
    }
    if caps & 0x04 != 0 {
        out.push("cbor");
    }
    if caps & 0x08 == 0 {
        out.push("msg");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_keys_sort_by_length_then_bytes() {
        assert!(text_key_order("rk", "alwaysUv"));
        assert!(text_key_order("alg", "type"));
        assert!(!text_key_order("type", "alg"));
        assert!(!text_key_order("rk", "rk"));
    }

    #[test]
    fn an_algorithm_with_no_name_keeps_its_number() {
        assert_eq!(cose_name(-36), Some("ES512"));
        assert_eq!(cose_name(-999), None);
    }

    #[test]
    fn capability_bit_three_is_nmsg() {
        assert_eq!(capability_names(0x05), vec!["wink", "cbor", "msg"]);
        assert_eq!(capability_names(0x0d), vec!["wink", "cbor"]);
        assert_eq!(capability_names(0x08), Vec::<&str>::new());
    }

    /// A minimal getInfo: one version, an AAGUID, one option, one algorithm.
    fn minimal() -> Vec<u8> {
        let mut w = vec![0xa4];
        w.extend_from_slice(&[0x01, 0x81, 0x68]);
        w.extend_from_slice(b"FIDO_2_0");
        w.push(0x03);
        w.extend_from_slice(&[0x50]);
        w.extend_from_slice(&[0u8; 16]);
        w.extend_from_slice(&[0x04, 0xa1, 0x62]);
        w.extend_from_slice(b"rk");
        w.push(0xf5);
        w.extend_from_slice(&[0x0a, 0x81, 0xa2, 0x63]);
        w.extend_from_slice(b"alg");
        w.push(0x26); // -7
        w.push(0x64);
        w.extend_from_slice(b"type");
        w.push(0x6a);
        w.extend_from_slice(b"public-key");
        w
    }

    #[test]
    fn reads_the_fields_ctap_numbers() {
        let info = parse_get_info(&minimal()).unwrap();
        assert_eq!(info.versions, vec!["FIDO_2_0"]);
        assert_eq!(info.aaguid.as_deref(), Some("00000000000000000000000000000000"));
        assert_eq!(info.options, vec![("rk".to_string(), true)]);
        assert_eq!(info.algorithms, vec![(-7, "ES256".to_string(), "public-key".to_string())]);
        assert!(info.non_canonical.is_none());
    }

    /// The whole reason this command exists: an algorithm nobody has heard of
    /// comes back as a number, not as the word "unknown".
    #[test]
    fn an_unrecognised_algorithm_is_reported_as_its_identifier() {
        let mut w = vec![0xa1, 0x0a, 0x81, 0xa1, 0x63];
        w.extend_from_slice(b"alg");
        w.extend_from_slice(&[0x38, 0x63]); // -100
        let info = parse_get_info(&w).unwrap();
        assert_eq!(info.algorithms, vec![(-100, String::new(), String::new())]);
    }

    #[test]
    fn a_field_this_tool_does_not_know_is_reported_and_not_dropped() {
        let w = vec![0xa1, 0x15, 0xf5]; // key 21, true
        let info = parse_get_info(&w).unwrap();
        assert_eq!(info.other_fields, vec![21]);
    }

    /// A real authenticator's bytes, from a different implementation entirely.
    ///
    /// exp178 drives OpenSK's engine in a host process and checks its
    /// `authenticatorGetInfo` in as hex, so this walker can be run against a
    /// device it has never met without one being plugged in. That file is
    /// committed, so unlike the released-image test in main.rs this one always
    /// runs.
    #[test]
    fn a_real_authenticators_getinfo() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../experiments/exp178-the-shape-of-the-contract/engine.json"
        );
        let Ok(text) = std::fs::read_to_string(path) else {
            return;
        };
        let hex = text
            .lines()
            .find_map(|l| l.trim().strip_prefix("\"getinfo_cbor\": \""))
            .and_then(|l| l.strip_suffix("\","))
            .expect("engine.json should carry getinfo_cbor");
        let bytes: Vec<u8> = (0..hex.len() / 2)
            .map(|i| u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).unwrap())
            .collect();

        let info = parse_get_info(&bytes).expect("OpenSK's getInfo should parse");
        assert!(info.versions.iter().any(|v| v == "FIDO_2_1"), "{:?}", info.versions);
        assert!(info.extensions.iter().any(|e| e == "hmac-secret"));
        assert!(info.options.iter().any(|(k, v)| k == "rk" && *v));
        assert!(info.algorithms.iter().any(|(a, n, _)| *a == -7 && n == "ES256"));
        assert_eq!(info.aaguid.as_deref(), Some("00000000000000000000000000000000"));
        assert!(info.non_canonical.is_none(), "{:?}", info.non_canonical);
        // Fields CTAP 2.1 defines past what this walker interprets. Reported,
        // which is the whole point.
        assert!(!info.other_fields.is_empty(), "should have listed the rest");
    }

    #[test]
    fn non_canonical_bytes_are_reported_and_not_refused() {
        // Keys 2 then 1: valid CBOR, and an order CTAP2 forbids.
        let w = vec![0xa2, 0x02, 0x80, 0x01, 0x80];
        let info = parse_get_info(&w).unwrap();
        assert!(info.non_canonical.is_some(), "should have noticed the key order");
        assert!(info.versions.is_empty());
    }
}
