//! One line of an HTTP request, and the single decision it is allowed to make.
//!
//! # Why this exists at all
//!
//! [exp150](../../../experiments/exp150-a-page-served-by-the-board/) served a
//! page and threw the request away, and said why in the code:
//!
//! > Parsing a request line means parsing untrusted input in a firmware, and
//! > every path through this server returns the same page, so there is nothing
//! > a path could select. exp151 is where a URL starts to mean something, and
//! > that is where the parser belongs.
//!
//! This is that parser, and it lives in a crate for the same reason
//! [`dhcp`](../../dhcp/) does: the interesting question is what happens to a
//! request that arrives *in pieces*, and a board is the worst place to ask it.
//! A TCP read returns whatever has arrived. Nothing promises that a request
//! line is in it.
//!
//! # The distinction the whole crate is built around
//!
//! **A truncation is not the same thing as a refusal.** `crates/dhcp` learned
//! this from a test that was written wrong twice, and HTTP has the same shape:
//!
//! ```text
//!   "GET /lo"                  not a request for /lo — the line has not ended
//!   "GET /log HTTP/1.1\r\n"    a request for /log
//!   "GET /lo\r\n"              a request for /lo, and it is refused for
//!                              having two parts instead of three
//! ```
//!
//! A parser that answers "unknown path" to the first one hands the caller a
//! 404 for something nobody asked for, and — worse on a socket — makes the
//! answer depend on how the host's TCP stack happened to split the packet.
//! [`Parsed::Incomplete`] is the only honest answer until a line terminator
//! arrives, and the test that matters cuts a real request at **every** offset
//! to prove nothing else is ever returned.
//!
//! # What it refuses, and why refusing is the feature
//!
//! Everything here is a subset chosen so that a firmware never has to decode
//! anything:
//!
//! - **No percent-decoding.** `/%6Cog` is not `/log`; it is a path with a `%`
//!   in it, and it is refused. Decoding is where a path parser starts being
//!   able to name files it was not meant to name, and this board has no files
//!   to name. Nothing is lost: the routes here are ASCII words.
//! - **No dot segments.** `..` is refused rather than resolved, for the same
//!   reason and with the same cost — none.
//! - **Origin-form only.** `GET http://elsewhere/log HTTP/1.1` is what a proxy
//!   is sent, and this board is not one. Refused, rather than quietly ignoring
//!   the part that says where it was really meant to go.
//! - **`GET` and `POST` only.** `HEAD` is refused, deliberately: answering a
//!   `HEAD` with a body is a worse bug than not answering it, and no route
//!   here needs one.
//!
//! The limits ([`MAX_LINE`], [`MAX_PATH`]) exist because the caller's buffer
//! does. A request line longer than the buffer is refused the moment it is
//! longer, not after the buffer has been filled.
//!
//! # What it does not do
//!
//! Headers. Not one. This crate reads the request *line* and stops, and the
//! caller reads the rest to the end of the request and discards it. That is
//! enough for every route in
//! [exp154](../../../experiments/exp154-one-port-four-doors/) — and the moment
//! it is not enough, the thing that is missing is `Host:` validation, which is
//! a security decision and gets its own experiment rather than a quiet
//! addition here.

#![no_std]
#![forbid(unsafe_code)]

// Only the tests allocate — they build request lines of a chosen length, which
// is the one thing a fixed buffer cannot express.
#[cfg(test)]
extern crate alloc;

/// The longest request line accepted, terminator excluded.
///
/// Not a protocol limit — HTTP has none — but a buffer limit, stated where it
/// can be tested. A client that sends more gets [`Refusal::LineTooLong`] as
/// soon as byte 257 arrives, which is what stops a long line from being a way
/// to make the board read forever.
pub const MAX_LINE: usize = 256;

/// The longest path accepted, after the query string is split off.
///
/// The longest route here is 7 bytes. Sixty-four leaves room for the routes an
/// experiment after this one might add, and refuses everything a scanner tries.
pub const MAX_PATH: usize = 64;

/// The longest query string accepted, `?` excluded.
pub const MAX_QUERY: usize = 64;

/// The two methods this board answers to.
///
/// Case-sensitive, because HTTP methods are: `get` is not `GET`, and treating
/// it as though it were is the first step of a parser that guesses.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Method {
    Get,
    Post,
}

/// Which of the board's doors a path names.
///
/// The table is here rather than in the firmware so that `cargo test` can
/// check it, and so that adding a route is a change to a crate with tests
/// rather than a string comparison buried in a socket loop.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Route {
    /// `/` — the index: what is here, and links to the rest.
    Index,
    /// `/log` — the retained log, the thing exp151 made reachable.
    Log,
    /// `/status` — link, lease, uptime, counters. Machine-readable.
    Status,
    /// `/trng` — bytes from the hardware random number generator.
    Trng,
    /// A path that is well-formed and names nothing. **This is not an error**
    /// — the request parsed. The caller answers 404, and the difference
    /// between this and a [`Refusal`] is the difference between a 404 and a
    /// 400.
    Unknown,
}

impl Route {
    /// The whole routing table, in one place, testable.
    ///
    /// A trailing slash has already been removed by [`parse`], so `/log/` and
    /// `/log` arrive here as the same string.
    pub fn of(path: &str) -> Route {
        match path.as_bytes() {
            b"/" => Route::Index,
            b"/log" => Route::Log,
            b"/status" => Route::Status,
            b"/trng" => Route::Trng,
            _ => Route::Unknown,
        }
    }
}

/// Why a completed request line was not accepted.
///
/// Every variant means the same thing operationally — the caller answers an
/// error and closes — but they are kept apart because the log line is what
/// somebody debugging on a phone will be reading, and "refused" tells them
/// nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    /// More than [`MAX_LINE`] bytes with no terminator in sight.
    LineTooLong,
    /// Not exactly `METHOD SP TARGET SP VERSION`.
    NotThreeParts,
    /// Parsed, but not a method this board answers.
    MethodNotAllowed,
    /// A target that is not origin-form — it does not begin with `/`.
    NotOriginForm,
    /// A path that is too long, or contains something this parser will not
    /// decode: `%`, `..`, or any byte outside a deliberately small set.
    PathNotUsable,
    /// A version this board does not speak.
    NotHttp11,
}

impl Refusal {
    /// The status code to answer with.
    ///
    /// 405 for the method, 400 for everything else. Kept here so the firmware
    /// cannot answer two different codes for the same refusal in two places.
    pub fn status(self) -> u16 {
        match self {
            Refusal::MethodNotAllowed => 405,
            _ => 400,
        }
    }

    /// A short reason, for the log and for the response body.
    pub fn reason(self) -> &'static str {
        match self {
            Refusal::LineTooLong => "request line too long",
            Refusal::NotThreeParts => "request line is not METHOD SP TARGET SP VERSION",
            Refusal::MethodNotAllowed => "only GET and POST",
            Refusal::NotOriginForm => "target must begin with /",
            Refusal::PathNotUsable => "path is too long or is not plain ASCII without % or ..",
            Refusal::NotHttp11 => "not HTTP/1.x",
        }
    }
}

/// A request line that was accepted.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Request<'a> {
    pub method: Method,
    /// The path, with any single trailing slash removed and the query split
    /// off. Never empty, always begins with `/`.
    pub path: &'a str,
    /// Everything after the first `?`, or `None` if there was none. Not
    /// parsed: no key-value splitting, no decoding. A route that wants a
    /// number out of it says so itself.
    pub query: Option<&'a str>,
    /// Which door this is, from [`Route::of`].
    pub route: Route,
    /// How many bytes the request line occupied, terminator included. The
    /// caller needs this to find the headers it is about to discard.
    pub line_len: usize,
}

/// What the bytes so far amount to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Parsed<'a> {
    /// A whole request line, and it is usable.
    Complete(Request<'a>),
    /// No line terminator yet, and not enough bytes to refuse on length. **Ask
    /// the socket for more.** Never an error, and never a 404.
    Incomplete,
    /// A whole line arrived and it is not one this board will act on.
    Refused(Refusal),
}

/// Read the first request line out of whatever has arrived.
///
/// Only the first: a client that pipelines two requests into one segment gets
/// the first one parsed and the second one left in the buffer, which is what
/// `line_len` is for. This board closes after one response, so the second is
/// discarded — but that is the caller's decision to make, not this crate's to
/// hide.
///
/// Both `\r\n` and a bare `\n` end the line. HTTP says CRLF, and every client
/// sends it; a bare LF is accepted so that
/// `printf 'GET /log HTTP/1.1\n\n' | nc …` is a thing a reader can type.
pub fn parse(buf: &[u8]) -> Parsed<'_> {
    let Some(nl) = buf.iter().position(|&b| b == b'\n') else {
        // No terminator. The only thing that can be decided without one is
        // that there will never be an acceptable one.
        return if buf.len() > MAX_LINE {
            Parsed::Refused(Refusal::LineTooLong)
        } else {
            Parsed::Incomplete
        };
    };
    let line_len = nl + 1;
    let mut line = &buf[..nl];
    if line.last() == Some(&b'\r') {
        line = &line[..line.len() - 1];
    }
    if line.len() > MAX_LINE {
        return Parsed::Refused(Refusal::LineTooLong);
    }

    // Exactly three parts, split on exactly one space each. Two spaces in a row
    // produce an empty part, and an empty part is a malformed line rather than
    // whitespace to be forgiving about — being forgiving here means two clients
    // can disagree about what was asked for.
    let mut parts = line.split(|&b| b == b' ');
    let (Some(method), Some(target), Some(version), None) =
        (parts.next(), parts.next(), parts.next(), parts.next())
    else {
        return Parsed::Refused(Refusal::NotThreeParts);
    };
    if method.is_empty() || target.is_empty() || version.is_empty() {
        return Parsed::Refused(Refusal::NotThreeParts);
    }

    let method = match method {
        b"GET" => Method::Get,
        b"POST" => Method::Post,
        _ => return Parsed::Refused(Refusal::MethodNotAllowed),
    };

    if !version.starts_with(b"HTTP/1.") {
        return Parsed::Refused(Refusal::NotHttp11);
    }

    if target[0] != b'/' {
        return Parsed::Refused(Refusal::NotOriginForm);
    }

    let (path, query) = match target.iter().position(|&b| b == b'?') {
        Some(q) => (&target[..q], Some(&target[q + 1..])),
        None => (&target[..], None),
    };

    // One trailing slash is removed, so `/log/` and `/log` are the same door.
    // Removing *all* of them would make `/log///` a request for the log too,
    // which is a different claim and not one worth making.
    let path = if path.len() > 1 && path[path.len() - 1] == b'/' {
        &path[..path.len() - 1]
    } else {
        path
    };

    if path.len() > MAX_PATH || !path_is_plain(path) {
        return Parsed::Refused(Refusal::PathNotUsable);
    }
    if let Some(q) = query {
        if q.len() > MAX_QUERY || !q.iter().all(|&b| is_printable_ascii(b)) {
            return Parsed::Refused(Refusal::PathNotUsable);
        }
    }

    // Both were checked byte by byte above, so neither conversion can fail —
    // but `unsafe` to say so would trade a real guarantee for nothing, since
    // this runs once per request on a link that is already the slow part.
    let (Ok(path), Some(query)) = (
        core::str::from_utf8(path),
        match query {
            None => Some(None),
            Some(q) => core::str::from_utf8(q).ok().map(Some),
        },
    ) else {
        return Parsed::Refused(Refusal::PathNotUsable);
    };

    Parsed::Complete(Request {
        method,
        path,
        query,
        route: Route::of(path),
        line_len,
    })
}

/// The one set of bytes a path may be made of.
///
/// Letters, digits, `/`, `-`, `_` and `.`, with `..` excluded separately. No
/// `%`, so nothing is ever decoded; no `\`, so nothing looks like a path on a
/// host that thinks in backslashes.
fn path_is_plain(path: &[u8]) -> bool {
    if path.windows(2).any(|w| w == b"..") {
        return false;
    }
    path.iter().all(|&b| {
        b.is_ascii_alphanumeric() || b == b'/' || b == b'-' || b == b'_' || b == b'.'
    })
}

fn is_printable_ascii(b: u8) -> bool {
    (0x21..=0x7e).contains(&b)
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloc::{format, vec};

    fn complete(buf: &[u8]) -> Request<'_> {
        match parse(buf) {
            Parsed::Complete(r) => r,
            other => panic!("expected a complete request, got {other:?}"),
        }
    }

    fn refusal(buf: &[u8]) -> Refusal {
        match parse(buf) {
            Parsed::Refused(r) => r,
            other => panic!("expected a refusal, got {other:?}"),
        }
    }

    #[test]
    fn the_four_doors() {
        for (target, want) in [
            ("/", Route::Index),
            ("/log", Route::Log),
            ("/status", Route::Status),
            ("/trng", Route::Trng),
        ] {
            let req = format!("GET {target} HTTP/1.1\r\n");
            let got = complete(req.as_bytes());
            assert_eq!(got.route, want, "{target}");
            assert_eq!(got.method, Method::Get);
            assert_eq!(got.query, None);
            assert_eq!(got.line_len, req.len());
        }
    }

    #[test]
    fn a_path_that_names_nothing_is_not_an_error() {
        // The distinction the caller turns into 404 versus 400.
        let req = complete(b"GET /favicon.ico HTTP/1.1\r\n");
        assert_eq!(req.route, Route::Unknown);
        assert_eq!(req.path, "/favicon.ico");
    }

    #[test]
    fn one_trailing_slash_is_the_same_door_and_two_are_not() {
        assert_eq!(complete(b"GET /log/ HTTP/1.1\r\n").route, Route::Log);
        assert_eq!(complete(b"GET /log// HTTP/1.1\r\n").route, Route::Unknown);
        // The root is one slash and keeps it.
        assert_eq!(complete(b"GET / HTTP/1.1\r\n").path, "/");
    }

    #[test]
    fn a_query_is_split_off_and_not_parsed() {
        let req = complete(b"GET /trng?n=16&fmt=hex HTTP/1.1\r\n");
        assert_eq!(req.route, Route::Trng);
        assert_eq!(req.path, "/trng");
        assert_eq!(req.query, Some("n=16&fmt=hex"));
    }

    #[test]
    fn post_is_accepted_and_head_is_not() {
        assert_eq!(complete(b"POST /log HTTP/1.1\r\n").method, Method::Post);
        assert_eq!(refusal(b"HEAD /log HTTP/1.1\r\n"), Refusal::MethodNotAllowed);
        assert_eq!(refusal(b"HEAD /log HTTP/1.1\r\n").status(), 405);
    }

    #[test]
    fn methods_are_case_sensitive() {
        assert_eq!(refusal(b"get /log HTTP/1.1\r\n"), Refusal::MethodNotAllowed);
    }

    #[test]
    fn nothing_is_ever_decoded() {
        // `%6C` is `l`. A parser that decodes answers /log here.
        assert_eq!(refusal(b"GET /%6Cog HTTP/1.1\r\n"), Refusal::PathNotUsable);
        assert_eq!(refusal(b"GET /../etc/passwd HTTP/1.1\r\n"), Refusal::PathNotUsable);
        assert_eq!(refusal(b"GET /log\\x HTTP/1.1\r\n"), Refusal::PathNotUsable);
    }

    #[test]
    fn a_proxy_style_target_is_refused_rather_than_half_understood() {
        assert_eq!(
            refusal(b"GET http://elsewhere.example/log HTTP/1.1\r\n"),
            Refusal::NotOriginForm
        );
    }

    #[test]
    fn shapes_that_are_not_a_request_line() {
        assert_eq!(refusal(b"GET /log\r\n"), Refusal::NotThreeParts);
        assert_eq!(refusal(b"GET  /log HTTP/1.1\r\n"), Refusal::NotThreeParts);
        assert_eq!(refusal(b"GET /log HTTP/1.1 extra\r\n"), Refusal::NotThreeParts);
        assert_eq!(refusal(b"\r\n"), Refusal::NotThreeParts);
        assert_eq!(refusal(b"GET /log HTTP/2\r\n"), Refusal::NotHttp11);
        assert_eq!(refusal(b"\x16\x03\x01\x02\x00 hello TLS\r\n"), Refusal::MethodNotAllowed);
    }

    #[test]
    fn a_bare_lf_ends_a_line_so_nc_works() {
        let req = complete(b"GET /log HTTP/1.1\n");
        assert_eq!(req.route, Route::Log);
        assert_eq!(req.line_len, 18);
    }

    #[test]
    fn length_is_refused_before_the_buffer_is_full() {
        // No terminator and already past the limit: decidable now.
        let long = vec![b'A'; MAX_LINE + 1];
        assert_eq!(parse(&long), Parsed::Refused(Refusal::LineTooLong));
        // One byte under, still nothing decidable.
        let almost = vec![b'A'; MAX_LINE];
        assert_eq!(parse(&almost), Parsed::Incomplete);
    }

    #[test]
    fn a_long_path_inside_a_legal_line_is_a_path_problem_not_a_line_problem() {
        let mut req = b"GET /".to_vec();
        req.extend(core::iter::repeat(b'a').take(MAX_PATH));
        req.extend_from_slice(b" HTTP/1.1\r\n");
        assert!(req.len() < MAX_LINE);
        assert_eq!(refusal(&req), Refusal::PathNotUsable);
    }

    /// The headline test, and the reason this is a crate.
    ///
    /// Cut a real request at every offset. Every short prefix has to be
    /// `Incomplete` — not a 404 for a truncated path, not a refusal for a line
    /// that has not finished arriving. What a TCP read returns is the host's
    /// business, and the answer may not depend on it.
    #[test]
    fn every_prefix_of_a_good_request_is_incomplete() {
        let full = b"GET /status?verbose=1 HTTP/1.1\r\nHost: 192.168.7.1\r\n\r\n";
        let line_end = 32; // index just past the first "\r\n"
        for cut in 0..line_end {
            assert_eq!(
                parse(&full[..cut]),
                Parsed::Incomplete,
                "a {cut}-byte prefix decided something"
            );
        }
        for cut in line_end..=full.len() {
            let req = complete(&full[..cut]);
            assert_eq!(req.route, Route::Status);
            assert_eq!(req.query, Some("verbose=1"));
            assert_eq!(req.line_len, line_end);
        }
    }

    /// And the same for a request that *will* be refused: the refusal must
    /// arrive when the line does, never before.
    #[test]
    fn a_refusal_never_arrives_early() {
        let full = b"DELETE /log HTTP/1.1\r\n\r\n";
        let line_end = 22;
        for cut in 0..line_end {
            assert_eq!(parse(&full[..cut]), Parsed::Incomplete, "cut at {cut}");
        }
        for cut in line_end..=full.len() {
            assert_eq!(refusal(&full[..cut]), Refusal::MethodNotAllowed);
        }
    }

    #[test]
    fn two_requests_in_one_read_yield_the_first_and_say_where_it_ended() {
        let both = b"GET /log HTTP/1.1\r\n\r\nGET /trng HTTP/1.1\r\n\r\n";
        let first = complete(both);
        assert_eq!(first.route, Route::Log);
        // The caller can find the second, and this board chooses not to.
        let rest = &both[first.line_len + 2..];
        assert_eq!(complete(rest).route, Route::Trng);
    }

    #[test]
    fn headers_after_the_line_are_none_of_this_crate_s_business() {
        // Not a captured request — the header names are the usual ones and the
        // order is arbitrary, because the assertion does not depend on either.
        // What it depends on is that a line followed by five more lines parses
        // exactly like a line followed by nothing.
        let req = complete(
            b"GET / HTTP/1.1\r\n\
              Host: 192.168.7.1\r\n\
              Connection: keep-alive\r\n\
              Upgrade-Insecure-Requests: 1\r\n\
              User-Agent: Mozilla/5.0\r\n\
              Accept: text/html\r\n\r\n",
        );
        assert_eq!(req.route, Route::Index);
        assert_eq!(req.line_len, 16);
    }
}
