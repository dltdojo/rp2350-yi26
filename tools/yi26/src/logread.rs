//! Reading the firmware's log, and understanding it well enough to be useful
//! to something that is not a person.
//!
//! The shell version was `stty -F PORT -icrnl` followed by `cat PORT`. That
//! works, and it hands you a wall of text. This opens the device directly —
//! so the terminal line discipline never gets to translate anything — and can
//! also report what an agent actually wants to know: did any lines go missing,
//! over what span, and where.

use std::io::{Read, Write};
use std::time::{Duration, Instant};

use crate::board::SAFE_BAUD;
use crate::out::{self, Opts};

/// One log line as the firmware sent it, taken apart.
///
/// The format comes from `crates/usb-log`:
///
/// ```text
/// [   21037 ms] (+26 lines lost) scheduler: 210 wakeups, worst lateness 7 us
/// ```
#[derive(Debug, PartialEq)]
pub struct Line {
    /// Milliseconds since the firmware booted, if the line carried a stamp.
    pub t_ms: Option<u64>,
    /// Lines the firmware dropped immediately before this one.
    pub lost: u64,
    /// The message, with the timestamp and loss marker removed.
    pub text: String,
    pub raw: String,
}

pub fn parse(raw: &str) -> Line {
    let raw_owned = raw.to_string();
    let mut rest = raw.trim_end_matches(['\r', '\n']);
    let mut t_ms = None;
    let mut lost = 0;

    if let Some(close) = rest.find(']') {
        if rest.starts_with('[') {
            let inside = rest[1..close].trim();
            if let Some(num) = inside.strip_suffix("ms") {
                if let Ok(v) = num.trim().parse::<u64>() {
                    t_ms = Some(v);
                    rest = rest[close + 1..].trim_start();
                }
            }
        }
    }

    if let Some(after) = rest.strip_prefix("(+") {
        if let Some(close) = after.find(')') {
            let marker = &after[..close];
            if let Some(n) = marker.strip_suffix(" lines lost") {
                if let Ok(v) = n.parse::<u64>() {
                    lost = v;
                    rest = after[close + 1..].trim_start();
                }
            }
        }
    }

    Line { t_ms, lost, text: rest.to_string(), raw: raw_owned }
}

#[derive(Default)]
pub struct Summary {
    pub lines: u64,
    pub lost_total: u64,
    /// How many times the log admitted to a gap. Distinct from `lost_total`:
    /// one gap can swallow many lines.
    pub gaps: u64,
    pub first_t_ms: Option<u64>,
    pub last_t_ms: Option<u64>,
}

/// Reads for `secs` seconds, printing as it goes, and returns what it saw.
///
/// Streams rather than buffering: a log you have to wait for is a log you
/// cannot use to watch something happen.
pub fn read(path: &str, secs: u64, opts: &Opts) -> Result<Summary, String> {
    let mut port = open(path)?;
    drain(&mut port, secs, opts)
}

/// Writes `payload` to the board, then reads for `secs` seconds and prints
/// whatever came back.
///
/// Sending and reading are one command, and one open port, on purpose.
/// Opening a CDC-ACM port asserts DTR and closing it drops DTR — and
/// `crates/usb-log` refuses to write a line while DTR is low, for the
/// hardware reason that crate's docs give. So `yi26 send hello` followed by a
/// separate `yi26 log` would close the port in between, and the firmware's
/// reply to what was just sent would land in the gap where nobody is
/// listening. Doing both through one handle means the port never closes
/// between the question and the answer.
pub fn send(path: &str, payload: &[u8], secs: u64, opts: &Opts) -> Result<Summary, String> {
    let mut port = open(path)?;

    port.write_all(payload).map_err(|e| format!("write failed on {path}: {e}"))?;
    port.flush().map_err(|e| format!("flush failed on {path}: {e}"))?;

    drain(&mut port, secs, opts)
}

fn open(path: &str) -> Result<Box<dyn serialport::SerialPort>, String> {
    // SAFE_BAUD, never the caller's choice. 1200 is the reboot signal from
    // exp105, and a tool that let you send text at an arbitrary rate would let
    // you reset the board by typing the wrong number.
    serialport::new(path, SAFE_BAUD)
        .timeout(Duration::from_millis(200))
        .open()
        .map_err(|e| format!("cannot open {path}: {e}"))
}

fn drain(
    port: &mut Box<dyn serialport::SerialPort>,
    secs: u64,
    opts: &Opts,
) -> Result<Summary, String> {
    let deadline = Instant::now() + Duration::from_secs(secs);
    let mut pending = Vec::new();
    let mut buf = [0u8; 512];
    let mut summary = Summary::default();

    while Instant::now() < deadline {
        match port.read(&mut buf) {
            Ok(0) => {}
            Ok(n) => {
                pending.extend_from_slice(&buf[..n]);
                while let Some(nl) = pending.iter().position(|&b| b == b'\n') {
                    let raw: Vec<u8> = pending.drain(..=nl).collect();
                    let text = String::from_utf8_lossy(&raw);
                    emit(&parse(&text), &mut summary, opts);
                }
            }
            // A timeout means "nothing arrived yet", which is the normal state
            // of a log. Anything else is the port going away under us.
            Err(e) if e.kind() == std::io::ErrorKind::TimedOut => {}
            Err(e) => return Err(format!("read failed: {e}")),
        }
    }

    if !pending.is_empty() {
        let text = String::from_utf8_lossy(&pending).to_string();
        emit(&parse(&text), &mut summary, opts);
    }

    if opts.json {
        println!(
            "{}",
            out::obj(&[
                out::kv_str("type", "summary"),
                out::kv_num("lines", summary.lines),
                out::kv_num("lost_total", summary.lost_total),
                out::kv_num("gaps", summary.gaps),
                out::kv_raw(
                    "first_t_ms",
                    &summary.first_t_ms.map(|v| v.to_string()).unwrap_or_else(|| "null".into())
                ),
                out::kv_raw(
                    "last_t_ms",
                    &summary.last_t_ms.map(|v| v.to_string()).unwrap_or_else(|| "null".into())
                ),
            ])
        );
    }
    Ok(summary)
}

fn emit(line: &Line, summary: &mut Summary, opts: &Opts) {
    if line.text.is_empty() && line.t_ms.is_none() {
        return;
    }
    summary.lines += 1;
    summary.lost_total += line.lost;
    if line.lost > 0 {
        summary.gaps += 1;
    }
    if let Some(t) = line.t_ms {
        summary.first_t_ms.get_or_insert(t);
        summary.last_t_ms = Some(t);
    }

    if opts.json {
        println!(
            "{}",
            out::obj(&[
                out::kv_str("type", "line"),
                out::kv_raw(
                    "t_ms",
                    &line.t_ms.map(|v| v.to_string()).unwrap_or_else(|| "null".into())
                ),
                out::kv_num("lost", line.lost),
                out::kv_str("text", &line.text),
            ])
        );
    } else {
        println!("{}", line.raw.trim_end_matches(['\r', '\n']));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_line() {
        let l = parse("[    1037 ms] scheduler: 10 wakeups\r\n");
        assert_eq!(l.t_ms, Some(1037));
        assert_eq!(l.lost, 0);
        assert_eq!(l.text, "scheduler: 10 wakeups");
    }

    #[test]
    fn line_after_a_gap() {
        let l = parse("[   21037 ms] (+26 lines lost) scheduler: 210 wakeups\r\n");
        assert_eq!(l.t_ms, Some(21037));
        assert_eq!(l.lost, 26);
        assert_eq!(l.text, "scheduler: 210 wakeups");
    }

    #[test]
    fn output_from_something_else_entirely() {
        // Not every board on 1209:0001 is ours, and a half-line can arrive
        // when a read starts mid-transmission. Neither may be dropped or
        // mangled — an agent needs to see exactly what came out.
        let l = parse("hello, no timestamp here\n");
        assert_eq!(l.t_ms, None);
        assert_eq!(l.lost, 0);
        assert_eq!(l.text, "hello, no timestamp here");
    }
}
