// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 rp2350-yi26 contributors

//! A CTAP-HID device with no board behind it.
//!
//! # What this is for
//!
//! [`tools/ctaphid/ctaphid.py`](../../ctaphid/ctaphid.py) grades a firmware on
//! ten cases where CTAP-HID says what the right answer is. Every one of them
//! costs a flash and a board. That is the correct price for grading a
//! *firmware* — and it is the wrong price for finding out that the suite itself
//! has a typo in it, which is what seven diverging copies of that client and a
//! page of never-run regexes have already cost this repository.
//!
//! So this binds a Unix socket and answers the same ten cases using
//! [`ctap_hid`] — the crate the firmware uses — and nothing else.
//!
//! ```sh
//! vctaphid --socket /tmp/v.sock &
//! python3 tools/ctaphid/ctaphid.py --socket /tmp/v.sock init
//! ```
//!
//! # What it does not prove, stated before anything it does
//!
//! **This is a pre-flight check, never a verification.** It exercises the
//! decisions and the client. It does not touch `embassy-usb`, the RP2350's USB
//! DPRAM, enumeration, timing, or Linux's `hidraw` — so a run of this is not
//! evidence about a board and must never fill an experiment's `Expected
//! output`. What it can say is that a change to `crates/ctap-hid` or to the
//! client did not break the ten answers, on a machine with nothing plugged in.
//!
//! # Why it holds no judgement of its own
//!
//! Every answer here comes out of the crate: [`Transaction::feed`] decides what
//! an arriving report means, [`init_reply`] builds the seventeen bytes, and
//! [`fragment`] cuts a reply into reports. What is left is the same three lines
//! [`ctap_hid::board`] leaves to a firmware — which commands this device
//! implements — because a second implementation of the transport would grade
//! itself rather than the crate.

use std::io::{self, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::time::{Duration, Instant};

use ctap_hid::{
    fragment, init_reply, next_cid, Action, Cid, Transaction, CTAPHID_ERROR, CTAPHID_INIT,
    CTAPHID_PING, ERR_INVALID_CHANNEL, ERR_INVALID_CMD, ERR_INVALID_PAR, ERR_MSG_TIMEOUT,
    MAX_MESSAGE, PACKET,
};

/// What an `INIT` reply advertises by default.
///
/// `CAPABILITY_NMSG` (0x08) and nothing else: this device answers `PING` and
/// refuses everything above the transport, so it must not claim `CBOR` (0x04).
/// exp169 measured what claiming a capability a build does not have costs, and
/// exp194 found the client's `unknown` case had been written against a device
/// whose claim did not match. It is a flag rather than a constant so that a
/// firmware's dishonest claim can be imitated on purpose.
const DEFAULT_CAPABILITIES: u8 = 0x08;

/// A measured wrong answer, on purpose.
///
/// A check that cannot fail is not a check. exp160 shipped one — it corrupted a
/// hex digit to `f` in a capture whose digit was already `f` — and it only
/// surfaced years of runs later. So this device can be asked to give the one
/// answer [exp194](../../../experiments/exp194-the-transport-that-drifted/)
/// actually measured a firmware giving: exp189 answered `ERR_INVALID_PAR` on a
/// channel it never allocated, where the specification names
/// `ERR_INVALID_CHANNEL`. `selftest.sh` asserts the suite catches it.
#[derive(PartialEq, Eq, Clone, Copy)]
enum Wrong {
    /// Answer every question correctly.
    Nothing,
    /// exp189's `bad-cid`: `ERR_INVALID_PAR` where `ERR_INVALID_CHANNEL` is due.
    BadCidPar,
}

/// How long to block when nothing is in flight. Any large value: a transaction
/// in flight always shortens it to its own deadline.
const IDLE_WAIT_MS: u64 = 3_600_000;

fn usage() -> ! {
    eprintln!(
        "vctaphid --socket PATH [--capabilities 0xNN] [--wrong NAME] [--once]\n\
         \n\
         A CTAP-HID device backed by crates/ctap-hid, over a Unix socket.\n\
         Answers PING; everything else above the transport is ERR_INVALID_CMD.\n\
         \n\
         --socket PATH        where to listen. An existing file is removed.\n\
         --capabilities 0xNN  the byte INIT advertises (default 0x08, NMSG).\n\
         --wrong bad-cid-par  answer ERR_INVALID_PAR where the specification\n\
         \x20                    names ERR_INVALID_CHANNEL, the way exp194\n\
         \x20                    measured exp189 doing. For proving the suite\n\
         \x20                    grades rather than describes.\n\
         --once               serve one client and exit."
    );
    std::process::exit(2)
}

fn main() -> io::Result<()> {
    let mut path: Option<String> = None;
    let mut capabilities = DEFAULT_CAPABILITIES;
    let mut wrong = Wrong::Nothing;
    let mut once = false;

    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--socket" => path = Some(args.next().unwrap_or_else(|| usage())),
            "--capabilities" => {
                let v = args.next().unwrap_or_else(|| usage());
                let v = v.strip_prefix("0x").unwrap_or(&v);
                capabilities = u8::from_str_radix(v, 16).unwrap_or_else(|_| usage());
            }
            "--wrong" => {
                wrong = match args.next().unwrap_or_else(|| usage()).as_str() {
                    "bad-cid-par" => Wrong::BadCidPar,
                    _ => usage(),
                }
            }
            "--once" => once = true,
            "-h" | "--help" => usage(),
            _ => usage(),
        }
    }
    let path = path.unwrap_or_else(|| usage());

    // A socket left behind by a killed run refuses the bind, and the message
    // ("Address already in use") names the wrong problem.
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path)?;

    // The line a script waits for. Printed after the bind, so a reader that has
    // seen it can connect without polling for the file.
    println!("ready {path}");
    io::stdout().flush()?;

    // Channel identifiers keep climbing across connections, the way they would
    // across two clients of one board. Nothing here depends on it; a device
    // that restarted its counter per client would be lying about being one
    // device.
    let mut counter = 0u32;
    let started = Instant::now();

    for stream in listener.incoming() {
        let mut stream = stream?;
        // A client that hangs up mid-message is a client, not a failure.
        if let Err(e) = serve(&mut stream, &mut counter, capabilities, wrong, started) {
            if e.kind() != io::ErrorKind::BrokenPipe && e.kind() != io::ErrorKind::ConnectionReset {
                eprintln!("vctaphid: {e}");
            }
        }
        if once {
            break;
        }
    }
    let _ = std::fs::remove_file(&path);
    Ok(())
}

/// One packet's worth of arrival, or the two things that are not one.
enum Got {
    Packet([u8; PACKET]),
    /// The read deadline passed with no whole report. The caller owes
    /// [`Transaction::expire`] a look.
    Timeout,
    Closed,
}

/// Read one 64-byte report, waiting at most `wait`.
///
/// `held` carries bytes across calls. A stream socket may split a write, and a
/// report arriving in two pieces is a transport artefact rather than anything
/// CTAP-HID has an opinion about — so a partial report is kept and the wait
/// resumes, and only an empty accumulator turns a deadline into [`Got::Timeout`].
fn read_report(stream: &mut UnixStream, held: &mut Vec<u8>, wait: Duration) -> io::Result<Got> {
    while held.len() < PACKET {
        stream.set_read_timeout(Some(wait.max(Duration::from_millis(1))))?;
        let mut chunk = [0u8; PACKET];
        match stream.read(&mut chunk) {
            Ok(0) => return Ok(Got::Closed),
            Ok(n) => held.extend_from_slice(&chunk[..n]),
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => return Ok(Got::Timeout),
            Err(e) if e.kind() == io::ErrorKind::TimedOut => return Ok(Got::Timeout),
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    let mut pkt = [0u8; PACKET];
    pkt.copy_from_slice(&held[..PACKET]);
    held.drain(..PACKET);
    Ok(Got::Packet(pkt))
}

/// Send a message, fragmented.
///
/// No report-number byte: that leading zero is a Linux `hidraw` convention the
/// client adds on its own transport, not part of CTAP-HID. Putting it here too
/// would make the socket and the board disagree about what a 64-byte report is.
fn send(stream: &mut UnixStream, cid: Cid, cmd: u8, data: &[u8]) -> io::Result<()> {
    let mut failed: Option<io::Error> = None;
    fragment(cid, cmd, data, |p| {
        if failed.is_none() {
            if let Err(e) = stream.write_all(p) {
                failed = Some(e);
            }
        }
    });
    match failed {
        Some(e) => Err(e),
        None => stream.flush(),
    }
}

/// The loop, on a socket.
///
/// It is [`ctap_hid::board::Wire::next`] with the two things that need a board
/// taken out — `HidReader`'s await becomes a read deadline, and `Instant` comes
/// from the host clock. The shape is the same on purpose: if the two ever
/// disagree about what a packet means, the crate is the one that is right and
/// this is the one that is wrong.
fn serve(
    stream: &mut UnixStream,
    counter: &mut u32,
    capabilities: u8,
    wrong: Wrong,
    started: Instant,
) -> io::Result<()> {
    let now_ms = || started.elapsed().as_millis() as u64;
    let mut transaction = Transaction::new();
    let mut held: Vec<u8> = Vec::with_capacity(PACKET);
    let mut body = [0u8; MAX_MESSAGE];

    loop {
        let wait = transaction.deadline_ms(now_ms()).unwrap_or(IDLE_WAIT_MS);
        match read_report(stream, &mut held, Duration::from_millis(wait))? {
            Got::Closed => return Ok(()),
            Got::Timeout => {
                // The half-sent message that will never be finished. Answering
                // it is the whole of the `truncated` case, and a device that
                // waits for the next packet instead holds the channel — and
                // while it is held, every other channel is refused.
                if let Some(cid) = transaction.expire(now_ms()) {
                    send(stream, cid, CTAPHID_ERROR, &[ERR_MSG_TIMEOUT])?;
                }
            }
            Got::Packet(pkt) => match transaction.feed(&pkt, now_ms()) {
                Action::Ignore(_) | Action::More => {}
                Action::Error(cid, code) => {
                    let code = match (wrong, code) {
                        (Wrong::BadCidPar, ERR_INVALID_CHANNEL) => ERR_INVALID_PAR,
                        _ => code,
                    };
                    send(stream, cid, CTAPHID_ERROR, &[code])?
                }
                Action::Complete => {
                    let (cid, cmd, data) = transaction.message();
                    if cmd == CTAPHID_INIT {
                        let reply = init_reply(data, next_cid(counter), capabilities);
                        transaction.clear();
                        send(stream, cid, CTAPHID_INIT, &reply)?;
                        continue;
                    }
                    let n = data.len();
                    body[..n].copy_from_slice(data);
                    transaction.clear();

                    // The only three lines that are this program's own, and the
                    // same three an experiment's `src/main.rs` keeps.
                    match cmd {
                        CTAPHID_PING => send(stream, cid, CTAPHID_PING, &body[..n])?,
                        _ => send(stream, cid, CTAPHID_ERROR, &[ERR_INVALID_CMD])?,
                    }
                }
            },
        }
    }
}
