//! Enough mDNS to answer to one name.
//!
//! [exp151](../../experiments/exp151-the-log-in-any-browser/) put the board's
//! log in any browser, and left half the problem standing: the address it is
//! served at is discovered by reading the log over CDC, which needs the WebUSB
//! that half was built to escape. A name fixes that — `http://yi26.local/` can
//! be typed by somebody who was never told a number.
//!
//! # Why this is small
//!
//! Android resolves `.local` by sending a **standard DNS query** to
//! `224.0.0.251:5353` and waiting for a reply — RFC 6762 §5.1, "one-shot
//! multicast DNS". It is not a full mDNS participant: it does not cache, it
//! does not do continuous queries, and it does not require the response to be
//! multicast. So a device that answers one-shot queries is reachable by name,
//! and a device that implements all of RFC 6762 is not more reachable.
//!
//! What is therefore *not* here, on purpose: probing and conflict resolution,
//! announcements, goodbye packets, known-answer suppression, service discovery
//! (`PTR`/`SRV`/`TXT`), and caching. Every one of those exists because a real
//! network has many responders on it. **A USB cable has one host on the other
//! end**, and the board is the only thing on it that could answer to anything.
//!
//! # What it refuses
//!
//! Each of these has been fed to it by a test, because a parser reached over a
//! multicast address is reached by whatever anything on the link feels like
//! sending:
//!
//! - a datagram shorter than a header
//! - a response rather than a query (a reply arriving on 5353 is somebody
//!   else answering, which is worth not parsing)
//! - a name whose length byte runs off the end of the buffer
//! - a compression pointer (a query for one name has nothing to compress, and
//!   following pointers is where DNS parsers grow their vulnerabilities)
//! - a question for a name that is not ours, or a type that is not `A`

#![no_std]
#![forbid(unsafe_code)]

/// The address one-shot queries arrive on.
pub const MULTICAST: [u8; 4] = [224, 0, 0, 251];
pub const PORT: u16 = 5353;

/// The fixed DNS header: id, flags, and four counts.
pub const HEADER_LEN: usize = 12;

/// Longest reply this crate will build: header, the echoed question, and one
/// answer record.
pub const REPLY_LEN: usize = 256;

const TYPE_A: u16 = 1;
const CLASS_IN: u16 = 1;
/// Bit 15 of the class field in an answer: "this is the only holder of this
/// name, replace anything you have". Set because it is true here.
const CACHE_FLUSH: u16 = 0x8000;
/// A response, authoritative.
const FLAGS_RESPONSE: u16 = 0x8400;

/// Why a datagram was not a question for us.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ignore {
    /// Shorter than a DNS header.
    TooShort,
    /// The QR bit is set: this is somebody's answer, not a question.
    NotAQuery,
    /// No questions in it.
    NoQuestion,
    /// A label length ran past the end of the buffer, or the name never ended.
    Malformed,
    /// A compression pointer. Legal in DNS, pointless in a single-question
    /// query, and the beginning of every parser that reads its own tail.
    Compressed,
    /// A perfectly good question about something else.
    NotOurName,
    /// Our name, but they asked for something we are not.
    NotAnARecord,
}

/// What a caller needs to build the reply: the query's id, and where in the
/// buffer the question ran, so it can be echoed back verbatim.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Question {
    pub id: u16,
    /// Byte range of the question section within the query.
    pub at: usize,
    pub len: usize,
}

/// Case-insensitive comparison of one label. DNS names are not case sensitive
/// and a resolver is free to randomise the case it asks in — some do it
/// deliberately, as a spoofing defence.
fn label_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len()
        && a.iter()
            .zip(b)
            .all(|(x, y)| x.eq_ignore_ascii_case(y))
}

/// Is this datagram a question for `name`, asked as `<name>.local`?
///
/// `name` is the first label only — pass `b"yi26"` to answer to `yi26.local`.
pub fn question_for(buf: &[u8], name: &[u8]) -> Result<Question, Ignore> {
    if buf.len() < HEADER_LEN {
        return Err(Ignore::TooShort);
    }
    let flags = u16::from_be_bytes([buf[2], buf[3]]);
    if flags & 0x8000 != 0 {
        return Err(Ignore::NotAQuery);
    }
    let qdcount = u16::from_be_bytes([buf[4], buf[5]]);
    if qdcount == 0 {
        return Err(Ignore::NoQuestion);
    }

    // Walk the first question's name. Only the first: a one-shot resolver asks
    // one thing, and answering the second question of a query that also asks
    // about somebody else is not this board's business.
    let start = HEADER_LEN;
    let mut i = start;
    let mut labels: [(usize, usize); 4] = [(0, 0); 4];
    let mut n = 0;
    loop {
        if i >= buf.len() {
            return Err(Ignore::Malformed);
        }
        let len = buf[i] as usize;
        if len & 0xc0 != 0 {
            return Err(Ignore::Compressed);
        }
        if len == 0 {
            i += 1;
            break;
        }
        let from = i + 1;
        if from + len > buf.len() {
            return Err(Ignore::Malformed);
        }
        if n < labels.len() {
            labels[n] = (from, len);
        }
        n += 1;
        i = from + len;
    }

    // `<name>.local` and nothing else — no subdomains, no bare name.
    if n != 2 {
        return Err(Ignore::NotOurName);
    }
    let (a0, l0) = labels[0];
    let (a1, l1) = labels[1];
    if !label_eq(&buf[a0..a0 + l0], name) || !label_eq(&buf[a1..a1 + l1], b"local") {
        return Err(Ignore::NotOurName);
    }

    if i + 4 > buf.len() {
        return Err(Ignore::Malformed);
    }
    let qtype = u16::from_be_bytes([buf[i], buf[i + 1]]);
    // The class is deliberately not checked against IN: the top bit is the
    // "unicast reply wanted" flag, and a resolver that sets it is still asking
    // the same question.
    if qtype != TYPE_A {
        return Err(Ignore::NotAnARecord);
    }

    Ok(Question {
        id: u16::from_be_bytes([buf[0], buf[1]]),
        at: start,
        len: i + 4 - start,
    })
}

/// Write the answer into `out`, returning its length.
///
/// The question is echoed back byte for byte out of the query, which is both
/// what the format wants and the only way to get the name right without
/// re-encoding it.
pub fn answer(
    query: &[u8],
    q: &Question,
    addr: [u8; 4],
    ttl: u32,
    out: &mut [u8],
) -> Option<usize> {
    let need = HEADER_LEN + q.len + q.len + 10 + 4;
    if out.len() < need || query.len() < q.at + q.len {
        return None;
    }
    out[0..2].copy_from_slice(&q.id.to_be_bytes());
    out[2..4].copy_from_slice(&FLAGS_RESPONSE.to_be_bytes());
    out[4..6].copy_from_slice(&1u16.to_be_bytes()); // QDCOUNT
    out[6..8].copy_from_slice(&1u16.to_be_bytes()); // ANCOUNT
    out[8..10].copy_from_slice(&0u16.to_be_bytes());
    out[10..12].copy_from_slice(&0u16.to_be_bytes());

    let mut i = HEADER_LEN;
    out[i..i + q.len].copy_from_slice(&query[q.at..q.at + q.len]);
    i += q.len;

    // The answer's name. A pointer to offset 12 would be legal and shorter —
    // and this crate refuses to *read* compression pointers, so writing one
    // would be asking of others what it will not do itself.
    let name_len = q.len - 4;
    out[i..i + name_len].copy_from_slice(&query[q.at..q.at + name_len]);
    i += name_len;
    out[i..i + 2].copy_from_slice(&TYPE_A.to_be_bytes());
    out[i + 2..i + 4].copy_from_slice(&(CLASS_IN | CACHE_FLUSH).to_be_bytes());
    out[i + 4..i + 8].copy_from_slice(&ttl.to_be_bytes());
    out[i + 8..i + 10].copy_from_slice(&4u16.to_be_bytes()); // RDLENGTH
    out[i + 10..i + 14].copy_from_slice(&addr);
    Some(i + 14)
}

#[cfg(test)]
extern crate alloc;

#[cfg(test)]
mod tests {
    use super::*;
    use alloc::vec::Vec;

    /// A query as a one-shot resolver sends it.
    fn query(labels: &[&[u8]], qtype: u16) -> Vec<u8> {
        let mut v = Vec::new();
        v.extend_from_slice(&0xbeefu16.to_be_bytes());
        v.extend_from_slice(&0u16.to_be_bytes()); // flags: a query
        v.extend_from_slice(&1u16.to_be_bytes()); // QDCOUNT
        v.extend_from_slice(&[0, 0, 0, 0, 0, 0]);
        for l in labels {
            v.push(l.len() as u8);
            v.extend_from_slice(l);
        }
        v.push(0);
        v.extend_from_slice(&qtype.to_be_bytes());
        v.extend_from_slice(&CLASS_IN.to_be_bytes());
        v
    }

    #[test]
    fn answers_its_own_name() {
        let q = query(&[b"yi26", b"local"], TYPE_A);
        let found = question_for(&q, b"yi26").unwrap();
        assert_eq!(found.id, 0xbeef);
        let mut out = [0u8; REPLY_LEN];
        let n = answer(&q, &found, [10, 42, 0, 213], 120, &mut out).unwrap();

        assert_eq!(u16::from_be_bytes([out[0], out[1]]), 0xbeef, "the id is echoed");
        assert_eq!(u16::from_be_bytes([out[2], out[3]]), FLAGS_RESPONSE);
        assert_eq!(u16::from_be_bytes([out[6], out[7]]), 1, "one answer");
        assert_eq!(&out[n - 4..n], &[10, 42, 0, 213], "the address is the last four bytes");
        // The cache-flush bit, which is what tells a resolver to replace
        // whatever it had rather than add to it.
        assert_eq!(u16::from_be_bytes([out[n - 12], out[n - 11]]) & CACHE_FLUSH, CACHE_FLUSH);
    }

    #[test]
    fn the_name_is_case_insensitive() {
        // Some resolvers randomise the case they ask in, deliberately.
        let q = query(&[b"Yi26", b"LOCAL"], TYPE_A);
        assert!(question_for(&q, b"yi26").is_ok());
    }

    #[test]
    fn somebody_elses_name_is_not_ours() {
        let q = query(&[b"printer", b"local"], TYPE_A);
        assert_eq!(question_for(&q, b"yi26"), Err(Ignore::NotOurName));
    }

    #[test]
    fn a_subdomain_of_our_name_is_not_our_name() {
        let q = query(&[b"www", b"yi26", b"local"], TYPE_A);
        assert_eq!(question_for(&q, b"yi26"), Err(Ignore::NotOurName));
    }

    #[test]
    fn a_question_that_is_not_an_a_record_is_left_alone() {
        let q = query(&[b"yi26", b"local"], 28); // AAAA
        assert_eq!(question_for(&q, b"yi26"), Err(Ignore::NotAnARecord));
    }

    #[test]
    fn an_answer_arriving_on_the_query_port_is_not_parsed_as_a_question() {
        let mut q = query(&[b"yi26", b"local"], TYPE_A);
        q[2] = 0x84; // QR set: this is a response
        assert_eq!(question_for(&q, b"yi26"), Err(Ignore::NotAQuery));
    }

    /// Compression pointers are legal DNS and are refused here. A query for one
    /// name has nothing to compress, and following pointers is where DNS
    /// parsers grow loops that read their own tails.
    #[test]
    fn a_compression_pointer_is_refused_not_followed() {
        let mut q = query(&[b"yi26", b"local"], TYPE_A);
        q[HEADER_LEN] = 0xc0;
        q[HEADER_LEN + 1] = 0x0c; // points at itself
        assert_eq!(question_for(&q, b"yi26"), Err(Ignore::Compressed));
    }

    #[test]
    fn a_label_that_runs_off_the_end_is_refused() {
        let mut q = query(&[b"yi26", b"local"], TYPE_A);
        // 60, and not 200: in DNS a length byte with its top two bits set is a
        // compression pointer, not a length. This test was written with 200
        // first and the parser was right — it reported `Compressed`, because
        // that is what 200 means. A label length can only be 0..=63.
        q[HEADER_LEN] = 60;
        assert_eq!(question_for(&q, b"yi26"), Err(Ignore::Malformed));
    }

    /// The same discipline `crates/dhcp` earned: a datagram arrives at whatever
    /// length the sender chose, and no length may panic or read past the end.
    #[test]
    fn no_truncation_panics_or_answers_wrongly() {
        let full = query(&[b"yi26", b"local"], TYPE_A);
        for n in 0..full.len() {
            match question_for(&full[..n], b"yi26") {
                Ok(_) => panic!("a {n}-byte datagram was treated as a question"),
                Err(_) => {}
            }
        }
        assert!(question_for(&full, b"yi26").is_ok(), "the whole one still parses");
    }

    #[test]
    fn a_buffer_too_small_writes_nothing() {
        let q = query(&[b"yi26", b"local"], TYPE_A);
        let found = question_for(&q, b"yi26").unwrap();
        let mut out = [0xAAu8; 20];
        assert!(answer(&q, &found, [1, 2, 3, 4], 120, &mut out).is_none());
        assert!(out.iter().all(|&b| b == 0xAA), "nothing was written");
    }
}
