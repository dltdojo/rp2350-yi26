//! `yi26` — the host side of the rp2350-yi26 experiments.
//!
//! Everything here used to be a shell function in `experiments/lib.sh`, built
//! out of `lsusb`, `lsblk`, `udisksctl`, `stty` and `/dev/serial/by-id`. Those
//! five are the only genuinely Linux-bound parts of this repository, and this
//! tool replaces them — one implementation instead of one per platform.
//!
//! Two things follow from that decision, and both are deliberate:
//!
//! **`--explain` prints what the equivalent would be by hand.** Replacing the
//! shell commands should not mean hiding them: this repository's scripts show
//! every command they run so that people learn the commands and not the script
//! names. Where there is no reasonable hand-typed equivalent, `--explain` says
//! so and says *why*, because "use the tool" is not an explanation.
//!
//! **`--json` is a first-class output, not a garnish.** The first user of this
//! tool is an AI agent helping somebody debug — theirs or ours. An agent given
//! human prose has to guess with regular expressions; an agent given a
//! document with a `problems` array can act. Every command supports it.
//!
//! Verified on Ubuntu Linux only. The portable crates underneath claim macOS
//! and Windows support and the code is written for it, but nobody has run it
//! there — see `tools/README.md`, which says so in the same words.

mod board;
mod drive;
mod logread;
mod out;
mod udev;

use std::path::{Path, PathBuf};
use std::time::Duration;

use out::{Explanation, Opts};

const VERSION: &str = env!("CARGO_PKG_VERSION");

/// UF2 family ID for rp2350-arm-s, at byte offset 28 of every block.
const RP2350_FAMILY: u32 = 0xE48B_FF59;

const USAGE: &str = "\
yi26 — host-side helper for the rp2350-yi26 experiments

usage: yi26 <command> [options]

commands:
  doctor            report everything observable about host and board
  state             print one word: bootsel, running, detached, or absent
  port              print the serial port of a board running these firmwares
  log               read the firmware's log
  send <text>       send bytes to the firmware, then read its reply
  flood             numbered packets at full speed (--packets N, --storm)
  bootsel           put the board into BOOTSEL mode (1200-baud touch)
  drive             print the RP2350 boot drive, mounting it if needed
  flash <file.uf2>  bootsel, mount, copy, and wait for the board to come back
  udev              can a browser open the board? (--install fixes it, Linux)
  detach            take the CDC interfaces from the kernel, so a browser can claim them
  attach            give them back — /dev/ttyACM0 returns

options:
  --json            machine-readable output on stdout (for scripts and agents)
  --explain         print the equivalent hand-typed commands on stderr, then act
  --install         `udev` only: write the rule as root instead of reporting
  --seconds N       how long to read for: `log` 10, `send` 3, `flood` 4
  --packets N       `flood` only: how many to send (default 2000)
  --storm           `flood` only: toggle RTS throughout, to cancel reads
  --version, -V
  --help, -h

`send` transmits the bytes literally and adds no trailing newline. Escapes are
understood so non-printable bytes can be sent: \\n \\r \\t \\0 \\\\ and \\xNN.

exit codes:
  0  success, or `doctor` found nothing wrong
  1  the thing asked for was not found, or the operation failed
  2  usage error
";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    std::process::exit(run(&args));
}

fn run(args: &[String]) -> i32 {
    let mut opts = Opts::default();
    let mut seconds: u64 = 10;
    let mut seconds_given = false;
    let mut install = false;
    let mut packets: u32 = 2000;
    let mut storm = false;
    let mut positional: Vec<String> = Vec::new();
    let mut i = 0;

    while i < args.len() {
        match args[i].as_str() {
            "--json" => opts.json = true,
            "--explain" => opts.explain = true,
            "--install" => install = true,
            "--seconds" => {
                i += 1;
                match args.get(i).and_then(|v| v.parse().ok()) {
                    Some(v) => {
                        seconds = v;
                        seconds_given = true;
                    }
                    None => return usage_error("--seconds needs a number"),
                }
            }
            "--storm" => storm = true,
            "--packets" => {
                i += 1;
                match args.get(i).and_then(|v| v.parse().ok()) {
                    Some(v) => packets = v,
                    None => return usage_error("--packets needs a number"),
                }
            }
            "--help" | "-h" => {
                print!("{USAGE}");
                return 0;
            }
            "--version" | "-V" => {
                println!("yi26 {VERSION}");
                return 0;
            }
            other if other.starts_with('-') => {
                return usage_error(&format!("unknown option: {other}"))
            }
            other => positional.push(other.to_string()),
        }
        i += 1;
    }

    let Some(command) = positional.first().cloned() else {
        print!("{USAGE}");
        return 2;
    };

    match command.as_str() {
        "doctor" => cmd_doctor(&opts),
        "state" => cmd_state(&opts),
        "port" => cmd_port(&opts),
        "log" => cmd_log(&opts, seconds),
        // A shorter default than `log`: this one is a question, and a firmware
        // that answers takes milliseconds to do it. `--seconds` still wins.
        "send" => match positional.get(1) {
            Some(text) => cmd_send(&opts, text, if seconds_given { seconds } else { 3 }),
            None => usage_error("send needs something to send"),
        },
        "flood" => cmd_flood(&opts, packets, storm, if seconds_given { seconds } else { 4 }),
        "bootsel" => cmd_bootsel(&opts),
        "drive" => cmd_drive(&opts),
        "flash" => match positional.get(1) {
            Some(f) => cmd_flash(&opts, Path::new(f)),
            None => usage_error("flash needs a .uf2 file"),
        },
        "udev" => cmd_udev(&opts, install),
        "detach" => cmd_kernel_driver(&opts, false),
        "attach" => cmd_kernel_driver(&opts, true),
        other => usage_error(&format!("unknown command: {other}")),
    }
}

fn usage_error(msg: &str) -> i32 {
    eprintln!("yi26: {msg}\n");
    eprint!("{USAGE}");
    2
}

/// Reports a failure in whichever format was asked for.
fn fail(opts: &Opts, id: &str, msg: &str, fix: &str) -> i32 {
    if opts.json {
        println!(
            "{}",
            out::obj(&[
                out::kv_bool("ok", false),
                out::kv_str("error", id),
                out::kv_str("message", msg),
                out::kv_str("fix", fix),
            ])
        );
    } else {
        eprintln!("yi26: {msg}");
        if !fix.is_empty() {
            eprintln!("      try: {fix}");
        }
    }
    1
}

// ---------------------------------------------------------------------------
// state

/// One word, no side effects, always exit 0.
///
/// `doctor` answers everything; this answers the one question a shell script
/// asks over and over — and it exists so that scripts do not have to pick
/// substrings out of JSON, which is exactly the fragile string-matching this
/// tool is meant to end.
/// The board's state in one word.
///
/// There are four, not three. `absent` used to cover two situations that need
/// opposite responses: nothing plugged in, and a board that is plugged in and
/// enumerated whose CDC interfaces have been taken from the kernel — which is
/// what `yi26 detach` does, and what exp116 requires. The second has no serial
/// port, so every check built on `find_port` called it missing and advised
/// changing the cable.
fn board_state(bootsel: bool, has_port: bool) -> &'static str {
    if bootsel {
        "bootsel"
    } else if has_port {
        "running"
    } else if board::exp_device_present() {
        "detached"
    } else {
        "absent"
    }
}

fn cmd_state(opts: &Opts) -> i32 {
    out::explain(
        opts,
        &Explanation {
            shell: &[
                "lsusb -d 2e8a:000f   # in BOOTSEL?",
                "lsusb -d 1209:0001   # on the bus at all?",
                "ls /dev/ttyACM*      # and does the kernel still drive it?",
            ],
            notes: &[
                "Three checks and an if/elif, on Linux only. The single word printed",
                "here means a script can branch on board state without parsing anything.",
                "The third check is why there are four words rather than three: a board",
                "whose interfaces have been detached is enumerated and has no serial",
                "port, and calling that 'absent' is how you end up looking for a bad",
                "cable while the board sits there working.",
            ],
        },
    );

    let state = board_state(board::in_bootsel(), board::find_port().is_some());

    if opts.json {
        println!("{}", out::obj(&[out::kv_str("state", state)]));
    } else {
        println!("{state}");
    }
    0
}

// ---------------------------------------------------------------------------
// port

fn cmd_port(opts: &Opts) -> i32 {
    out::explain(
        opts,
        &Explanation {
            shell: &["ls -l /dev/serial/by-id/", "lsusb -d 1209:0001"],
            notes: &[
                "/dev/serial/by-id only exists on Linux, and lsusb only lists USB —",
                "neither can tell you which tty belongs to which device on other platforms.",
                "This asks the operating system's own serial enumeration, which reports",
                "the USB vendor and product behind each port on every platform.",
            ],
        },
    );

    match board::find_port() {
        Some(p) => {
            if opts.json {
                println!("{}", port_json(&p));
            } else {
                println!("{}", p.path);
            }
            0
        }
        None => fail(
            opts,
            "no-port",
            "no board running one of these firmwares is attached",
            "plug the board in with a data cable, or flash a firmware first (exp103)",
        ),
    }
}

fn port_json(p: &board::Port) -> String {
    out::obj(&[
        out::kv_str("path", &p.path),
        out::kv_str("vid", &format!("0x{:04x}", p.vid)),
        out::kv_str("pid", &format!("0x{:04x}", p.pid)),
        out::kv_opt("product", p.product.as_deref()),
        out::kv_opt("serial_number", p.serial.as_deref()),
        out::kv_opt("manufacturer", p.manufacturer.as_deref()),
    ])
}

// ---------------------------------------------------------------------------
// log

fn cmd_log(opts: &Opts, seconds: u64) -> i32 {
    out::explain(
        opts,
        &Explanation {
            shell: &["stty -F /dev/ttyACM0 -icrnl", "timeout 10 cat /dev/ttyACM0"],
            notes: &[
                "The -icrnl is not optional: the firmware ends lines with CR+LF, and the",
                "terminal line discipline turns that CR into a second newline, so a plain",
                "cat shows a blank line after every entry. Opening the device directly, as",
                "this does, never involves a line discipline at all.",
                "What has no shell equivalent is --json: parsing timestamps and loss",
                "markers back out of the text, and reporting how many lines went missing",
                "over what span. That is the part an agent actually needs.",
            ],
        },
    );

    let Some(p) = board::find_port() else {
        return fail(
            opts,
            "no-port",
            "no board running one of these firmwares is attached",
            "yi26 doctor",
        );
    };

    match logread::read(&p.path, seconds, opts) {
        Ok(_) => 0,
        Err(e) => fail(opts, "read-failed", &e, "check nothing else holds the port: fuser -v <port>"),
    }
}

// ---------------------------------------------------------------------------
// send

fn cmd_send(opts: &Opts, text: &str, seconds: u64) -> i32 {
    out::explain(
        opts,
        &Explanation {
            shell: &[
                "stty -F /dev/ttyACM0 115200 -icrnl",
                "printf 'hello' > /dev/ttyACM0",
                "timeout 3 cat /dev/ttyACM0",
            ],
            notes: &[
                "Three commands, and the middle one is a trap. Each redirection opens and",
                "closes the port, and closing it drops DTR — which is the signal",
                "crates/usb-log waits for before it writes anything. So the firmware's",
                "reply to what you just sent can land in the gap between the printf and",
                "the cat, and you see nothing. This sends and listens through one open",
                "handle, so there is no gap.",
                "The rate is always 115200 and cannot be changed here. 1200 is exp105's",
                "reboot signal, and a send command that took a baud rate would let a typo",
                "reset the board.",
            ],
        },
    );

    let payload = match unescape(text) {
        Ok(p) => p,
        Err(e) => return fail(opts, "bad-escape", &e, "yi26 send --help"),
    };

    let Some(p) = board::find_port() else {
        return fail(
            opts,
            "no-port",
            "no board running one of these firmwares is attached",
            "yi26 doctor",
        );
    };

    match logread::send(&p.path, &payload, seconds, opts) {
        Ok(_) => 0,
        Err(e) => fail(opts, "send-failed", &e, "check nothing else holds the port: fuser -v <port>"),
    }
}

/// Turns the escapes a shell would eat into the bytes they name.
///
/// The bytes sent are exactly the bytes given — no trailing newline is added.
/// A firmware reading a bulk endpoint receives a packet, not a line, and a
/// newline nobody asked for shows up in the receiver's hex dump as a byte the
/// sender never typed.
fn unescape(s: &str) -> Result<Vec<u8>, String> {
    let mut out = Vec::with_capacity(s.len());
    let mut chars = s.chars();

    while let Some(c) = chars.next() {
        if c != '\\' {
            let mut buf = [0u8; 4];
            out.extend_from_slice(c.encode_utf8(&mut buf).as_bytes());
            continue;
        }
        match chars.next() {
            Some('n') => out.push(b'\n'),
            Some('r') => out.push(b'\r'),
            Some('t') => out.push(b'\t'),
            Some('0') => out.push(0),
            Some('\\') => out.push(b'\\'),
            Some('x') => {
                let hi = chars.next();
                let lo = chars.next();
                match (hi, lo) {
                    (Some(hi), Some(lo)) => {
                        let pair: String = [hi, lo].iter().collect();
                        match u8::from_str_radix(&pair, 16) {
                            Ok(b) => out.push(b),
                            Err(_) => return Err(format!("\\x{pair} is not two hex digits")),
                        }
                    }
                    _ => return Err("\\x needs two hex digits after it".into()),
                }
            }
            Some(other) => return Err(format!("unknown escape: \\{other}")),
            None => return Err("trailing backslash with nothing after it".into()),
        }
    }
    Ok(out)
}

// ---------------------------------------------------------------------------
// flood

fn cmd_flood(opts: &Opts, packets: u32, storm: bool, seconds: u64) -> i32 {
    out::explain(
        opts,
        &Explanation {
            shell: &[],
            notes: &[
                "No shell equivalent, and the reason is the point of the command. It has",
                "to write 64-byte packets at full speed while, at the same time and from",
                "another thread, toggling RTS on the same open port. A shell can do the",
                "first with dd and the second with stty, but not both at once through one",
                "handle — and if they are not at once, nothing gets cancelled.",
                "Each packet carries its sequence number in the first four bytes,",
                "little-endian. Sequence 0 goes first and tells exp119 to clear its",
                "counters, so two runs do not look like one enormous gap.",
                "RTS rather than DTR: both fire the device's control_changed(), but",
                "crates/usb-log will not write while DTR is low, so a DTR storm would",
                "silence the log this command exists to read.",
            ],
        },
    );

    let Some(p) = board::find_port() else {
        return fail(
            opts,
            "no-port",
            "no board running one of these firmwares is attached",
            "yi26 doctor",
        );
    };

    match logread::flood(&p.path, packets, storm, seconds, opts) {
        Ok(_) => 0,
        Err(e) => fail(opts, "flood-failed", &e, "check nothing else holds the port: fuser -v <port>"),
    }
}

// ---------------------------------------------------------------------------
// bootsel

fn cmd_bootsel(opts: &Opts) -> i32 {
    out::explain(
        opts,
        &Explanation {
            shell: &[
                "stty -F /dev/ttyACM0 115200",
                "sleep 1",
                "stty -F /dev/ttyACM0 1200",
            ],
            notes: &[
                "Two stty calls, not one: if the port already happens to be at 1200, asking",
                "for 1200 changes nothing, so no SET_LINE_CODING goes out and the firmware",
                "never hears the request. Bouncing via 115200 makes it unconditional.",
                "This tool changes the rate on an already-open port instead, which is",
                "unconditional by construction, and holds the port open for a second",
                "afterwards — the firmware resets 250 ms in, and closing underneath that",
                "leaves a board that is enumerated and dead (exp105 measured it).",
                "Only firmware built with crates/usb-reboot responds. exp103 and exp104",
                "do not, and for those the button is the answer.",
            ],
        },
    );

    if board::in_bootsel() {
        return bootsel_ok(opts, "already", 0);
    }

    // Two routes to the same request, because there are two ways the board can
    // be present.
    //
    // Normally the kernel's cdc_acm driver owns the interface and hands out
    // /dev/ttyACM0, so the touch goes through the serial port. But exp116
    // needs that driver detached — Chrome's WebUSB will not do it, so `yi26
    // detach` does — and with it gone there is no serial port and nothing to
    // set a baud rate on. Without the second route, detaching would turn a
    // hands-free reflash into a BOOTSEL press, which is exactly the trap this
    // repository keeps warning about.
    //
    // The firmware cannot tell them apart: crates/usb-reboot reads the line
    // coding, not the driver that set it.
    let touched = match board::find_port() {
        Some(p) => board::touch_1200(&p.path),
        None => board::touch_1200_raw(),
    };
    if let Err(e) = touched {
        // The fix has to match the failure. Telling someone to hold BOOTSEL
        // when the real problem is a browser tab sends them to a physical
        // button for a software conflict — and if their board is in another
        // room, that advice costs them the afternoon.
        let fix = if e.contains("held by something else") {
            "close the browser tab connected to the board, then try again"
        } else {
            "hold BOOTSEL while plugging the board in"
        };
        return fail(opts, "touch-failed", &e, fix);
    }

    if board::wait_for_bootsel(Duration::from_secs(10)) {
        bootsel_ok(opts, "1200-baud touch", 0)
    } else {
        fail(
            opts,
            "no-reboot",
            "the board did not reach BOOTSEL mode",
            "this firmware may predate crates/usb-reboot, or was built with \
             --no-default-features; hold BOOTSEL while plugging in",
        )
    }
}

fn bootsel_ok(opts: &Opts, method: &str, code: i32) -> i32 {
    if opts.json {
        println!(
            "{}",
            out::obj(&[
                out::kv_bool("ok", true),
                out::kv_str("state", "bootsel"),
                out::kv_str("method", method),
            ])
        );
    } else {
        println!("board is in BOOTSEL mode ({method})");
    }
    code
}

// ---------------------------------------------------------------------------
// drive

fn cmd_drive(opts: &Opts) -> i32 {
    out::explain(
        opts,
        &Explanation {
            shell: &[
                "lsblk -rno NAME,LABEL | awk '$2 == \"RP2350\" {print $1}'",
                "udisksctl mount -b /dev/sdb1",
                "lsblk -rno LABEL,MOUNTPOINT",
            ],
            notes: &[
                "lsblk is Linux-only, and matching on the volume label trusts a name.",
                "This looks instead for a mounted filesystem containing INFO_UF2.TXT —",
                "the file the ROM itself writes — so the drive is identified by what it",
                "is rather than what it is called, with the same test everywhere.",
                "Mounting still shells out to udisksctl on Linux: unprivileged mounting",
                "is the operating system's job, not this tool's. macOS and Windows mount",
                "removable media on their own and need no equivalent step.",
            ],
        },
    );

    match drive::find_or_mount() {
        Ok(d) => {
            if opts.json {
                println!(
                    "{}",
                    out::obj(&[
                        out::kv_bool("ok", true),
                        out::kv_str("path", &d.path.to_string_lossy()),
                        out::kv_opt("info_uf2", d.info.as_deref()),
                    ])
                );
            } else {
                println!("{}", d.path.display());
            }
            0
        }
        Err(e) => fail(opts, "no-drive", &e, "yi26 bootsel"),
    }
}

// ---------------------------------------------------------------------------
// flash

fn cmd_flash(opts: &Opts, uf2: &Path) -> i32 {
    out::explain(
        opts,
        &Explanation {
            shell: &[
                "od -An -tx4 -j28 -N4 firmware.uf2      # family ID must be e48bff59",
                "stty -F /dev/ttyACM0 115200; sleep 1; stty -F /dev/ttyACM0 1200",
                "udisksctl mount -b /dev/sdb1",
                "cp firmware.uf2 /media/you/RP2350/",
            ],
            notes: &[
                "The copy is the flash: the ROM watches the drive, writes what lands there",
                "to flash, and reboots — which is why the drive vanishes mid-copy and your",
                "file manager may complain. That is success, not failure (exp101).",
                "This checks the family ID before copying, because a UF2 built for another",
                "chip is silently ignored by the ROM, which looks exactly like a board that",
                "did not come back.",
            ],
        },
    );

    let bytes = match std::fs::read(uf2) {
        Ok(b) => b,
        Err(e) => return fail(opts, "no-file", &format!("cannot read {}: {e}", uf2.display()), "cargo build --release && elf2flash convert -b rp2350 <elf> <uf2>"),
    };
    if let Err(e) = check_uf2_family(&bytes) {
        return fail(opts, "wrong-family", &e, "elf2flash convert -b rp2350 <elf> <uf2>");
    }

    if !board::in_bootsel() {
        if let Some(p) = board::find_port() {
            if let Err(e) = board::touch_1200(&p.path) {
                return fail(opts, "touch-failed", &e, "hold BOOTSEL while plugging the board in");
            }
        }
        if !board::wait_for_bootsel(Duration::from_secs(10)) {
            return fail(
                opts,
                "no-bootsel",
                "the board is not in BOOTSEL mode and did not get there on its own",
                "hold BOOTSEL while plugging the board in",
            );
        }
    }

    let d = match drive::find_or_mount() {
        Ok(d) => d,
        Err(e) => return fail(opts, "no-drive", &e, "check that the board is in BOOTSEL mode"),
    };

    let dest = d.path.join(uf2.file_name().unwrap_or_else(|| std::ffi::OsStr::new("firmware.uf2")));
    if let Err(e) = std::fs::write(&dest, &bytes) {
        // The drive disappearing mid-write is the ROM doing its job. Only
        // report it if the board then fails to come back.
        let benign = matches!(
            e.kind(),
            std::io::ErrorKind::NotFound | std::io::ErrorKind::BrokenPipe
        ) || e.raw_os_error() == Some(5);
        if !benign {
            return fail(opts, "copy-failed", &format!("cannot write {}: {e}", dest.display()), "");
        }
    }

    let port = board::wait_for_port(Duration::from_secs(20));
    match port {
        Some(p) => {
            if opts.json {
                println!(
                    "{}",
                    out::obj(&[
                        out::kv_bool("ok", true),
                        out::kv_str("flashed", &uf2.display().to_string()),
                        out::kv_num("bytes", bytes.len() as u64),
                        out::kv_raw("port", &port_json(&p)),
                    ])
                );
            } else {
                println!("flashed {} ({} bytes), running at {}", uf2.display(), bytes.len(), p.path);
            }
            0
        }
        None => fail(
            opts,
            "no-return",
            "the board did not come back as a serial port after flashing",
            "some firmwares have no USB at all (exp103) — check the LED instead",
        ),
    }
}

fn check_uf2_family(bytes: &[u8]) -> Result<(), String> {
    if bytes.len() < 32 {
        return Err("not a UF2 file (too short)".to_string());
    }
    let family = u32::from_le_bytes([bytes[28], bytes[29], bytes[30], bytes[31]]);
    if family == RP2350_FAMILY {
        Ok(())
    } else {
        Err(format!(
            "UF2 family ID is {family:08x}, expected {RP2350_FAMILY:08x} (rp2350-arm-s) — \
             this file is for a different chip"
        ))
    }
}

// ---------------------------------------------------------------------------
// detach / attach

/// Moves the CDC interfaces between the kernel and userspace.
///
/// Needed because of a measured Chrome behaviour, not a theoretical one: on
/// Linux, WebUSB's `claimInterface` does not detach `cdc_acm`, so a page that
/// wants the CDC interfaces gets `NetworkError: Unable to claim interface` and
/// no hint about why. The kernel is willing — detaching here and claiming in
/// the browser both succeed.
///
/// The trade is real and is printed rather than buried: with the driver gone
/// there is no `/dev/ttyACM0`, so `yi26 log` and every terminal program stop
/// seeing the board. Flashing still works, because `bootsel` has a second
/// implementation that does not need a serial port.
fn cmd_kernel_driver(opts: &Opts, attach: bool) -> i32 {
    out::explain(
        opts,
        &Explanation {
            shell: &[
                "# by hand, as root, per interface:",
                "echo -n 1-7:1.0 > /sys/bus/usb/drivers/cdc_acm/unbind",
                "echo -n 1-7:1.1 > /sys/bus/usb/drivers/cdc_acm/unbind",
            ],
            notes: &[
                "The sysfs route needs root and the exact bus path, which changes every",
                "time the board is plugged into a different port. This does it through",
                "usbfs with the access the udev rule already granted — no password, and",
                "the interface numbers are read from the descriptors rather than assumed.",
            ],
        },
    );

    let result = if attach {
        board::attach_kernel_driver()
    } else {
        board::detach_kernel_driver()
    };

    match result {
        Ok(ifaces) => {
            let list: Vec<String> = ifaces.iter().map(|n| n.to_string()).collect();
            if opts.json {
                println!(
                    "{}",
                    out::obj(&[
                        out::kv_bool("ok", true),
                        out::kv_str("action", if attach { "attach" } else { "detach" }),
                        out::kv_str("interfaces", &list.join(",")),
                    ])
                );
            } else if attach {
                println!("attached kernel driver to interface(s) {}", list.join(", "));
                println!("      /dev/ttyACM0 is back; `yi26 log` works again");
            } else {
                println!("detached kernel driver from interface(s) {}", list.join(", "));
                println!("      a browser can claim them now — and /dev/ttyACM0 is gone");
                println!("      until `yi26 attach`, a replug, or a reflash");
            }
            0
        }
        Err(e) => fail(
            opts,
            if attach { "attach-failed" } else { "detach-failed" },
            &e,
            if attach {
                "close any browser tab holding the device first"
            } else {
                "check the board is attached, and `yi26 udev` for permissions"
            },
        ),
    }
}

// ---------------------------------------------------------------------------
// udev

/// Reports whether a browser could open the board, and optionally fixes it.
///
/// The report is the default and the fix is opt-in, because this is the only
/// subcommand that touches anything outside the repository. Nothing here runs
/// as root unless `--install` was typed.
fn cmd_udev(opts: &Opts, install: bool) -> i32 {
    out::explain(
        opts,
        &Explanation {
            shell: &[
                "# check: is the board's node openable read-write?",
                "ls -l /dev/bus/usb/*/*    # then match bus/device from lsusb",
                "# fix:",
                "sudo tee /etc/udev/rules.d/70-rp2350-yi26.rules   # rule text below",
                "sudo udevadm control --reload",
                "sudo udevadm trigger --subsystem-match=usb --attr-match=idVendor=1209",
                "sudo udevadm settle",
            ],
            notes: &[
                "The check here is not the `ls` above. It opens the device the way a",
                "browser does, because a rule that exists but does not work is worse",
                "than no rule — it sends you looking in the wrong place.",
                "TAG+=\"uaccess\" is the narrow fix: access goes to whoever is logged in",
                "at this seat, not to a group and not to every account on the machine.",
            ],
        },
    );

    if install {
        if opts.json {
            // Installing prints a sudo prompt and root's output; interleaving
            // that with a JSON document would produce neither.
            return fail(
                opts,
                "json-with-install",
                "--install is interactive (sudo) and cannot produce clean JSON",
                "run `yi26 udev --install` on its own, then `yi26 udev --json` to verify",
            );
        }
        eprintln!("yi26: installing {}", udev::RULE_PATH);
        eprintln!("      this needs root, so sudo will ask for your password once.");
        eprintln!();
        if let Err(e) = udev::install() {
            return fail(
                opts,
                "install-failed",
                &e,
                "run the commands from `yi26 udev --explain` by hand",
            );
        }
        eprintln!();
    }

    // After an install, give the device a moment before believing a failure.
    //
    // `udevadm settle` in the script above is the real fix for the race that
    // used to happen here, and this is the belt to its braces: applying an
    // ACL is asynchronous in ways a shell command cannot fully promise, and
    // telling someone their fix did not work when it did is the worst
    // possible output from a tool whose whole job is answering that question.
    let mut a = udev::check();
    if install && !a.open_ok && a.present {
        for _ in 0..10 {
            std::thread::sleep(Duration::from_millis(300));
            a = udev::check();
            if a.open_ok {
                break;
            }
        }
    }

    if opts.json {
        println!(
            "{}",
            out::obj(&[
                out::kv_bool("ok", a.open_ok),
                out::kv_bool("present", a.present),
                out::kv_opt("node", a.node.as_deref()),
                out::kv_bool("rule_installed", a.rule_installed),
                out::kv_str("rule_path", udev::RULE_PATH),
                out::kv_opt("error", a.error.as_deref()),
            ])
        );
        return if a.open_ok { 0 } else { 1 };
    }

    if !a.present {
        eprintln!("yi26: no board on USB, so there is nothing to test access against");
        eprintln!("      plug it in and run this again");
        return 1;
    }

    let node = a.node.as_deref().unwrap_or("(unknown)");
    if a.open_ok {
        println!("ok    {node} opens read-write — a browser can claim this board");
        if !a.rule_installed {
            println!("note  {} is not present; something else is", udev::RULE_PATH);
            println!("      granting the access. Nothing to do.");
        }
        return 0;
    }

    println!("FAIL  {node} will not open read-write");
    if let Some(e) = &a.error {
        println!("      {e}");
    }
    println!();
    if a.rule_installed {
        println!("The rule at {} is already there, so either it has", udev::RULE_PATH);
        println!("not been applied to this already-plugged board, or something else is");
        println!("wrong. Unplug the board and plug it back in, then run this again.");
    } else {
        println!("Chrome's first Connect will fail with \"Access denied\". To fix it:");
        println!();
        println!("    yi26 udev --install");
        println!();
        println!("That writes one udev rule and asks for your password once. Run");
        println!("`yi26 udev --explain` first if you would rather type it yourself.");
    }
    1
}

// ---------------------------------------------------------------------------
// doctor

struct Problem {
    id: &'static str,
    severity: &'static str,
    message: String,
    fix: &'static str,
}

fn cmd_doctor(opts: &Opts) -> i32 {
    out::explain(
        opts,
        &Explanation {
            shell: &[],
            notes: &[
                "There is no single command for this, and composing one out of lsusb,",
                "lsblk, stty, command -v and ls would produce a page of human-readable",
                "prose that a program can only consume by guessing at it with regular",
                "expressions.",
                "That is the whole reason this subcommand exists: one document, one",
                "schema, a problems array with an id and a fix for each entry. Run it",
                "with --json and hand the output to whatever is helping you debug.",
            ],
        },
    );

    let mut problems: Vec<Problem> = Vec::new();

    // -- host ---------------------------------------------------------------
    let os = std::env::consts::OS;
    let verified = os == "linux";
    if !verified {
        problems.push(Problem {
            id: "host-unverified",
            severity: "warn",
            message: format!(
                "this tool has been verified on Linux only; you are on {os}, where nobody has run it yet"
            ),
            fix: "expect rough edges, and please report what happens",
        });
    }

    // -- toolchain ----------------------------------------------------------
    let cargo = which("cargo");
    let rustup = which("rustup");
    let elf2flash = which("elf2flash");
    if cargo.is_none() {
        problems.push(Problem {
            id: "no-cargo",
            severity: "error",
            message: "cargo is not on PATH".to_string(),
            fix: "experiments/exp102-rust-toolchain/run.sh",
        });
    }
    if elf2flash.is_none() {
        problems.push(Problem {
            id: "no-elf2flash",
            severity: "error",
            message: "elf2flash is not on PATH — nothing can be converted to UF2".to_string(),
            fix: "cargo install elf2flash",
        });
    }

    // -- board --------------------------------------------------------------
    let bootsel = board::in_bootsel();
    let port = board::find_port();
    let state = board_state(bootsel, port.is_some());
    let holders = if state == "detached" { board::usbfs_holders() } else { Vec::new() };

    if state == "absent" {
        problems.push(Problem {
            id: "no-board",
            severity: "warn",
            message: "no RP2350 board found on USB".to_string(),
            fix: "plug it in with a data cable, not a charge-only one — exp101 explains how to tell",
        });
    }

    // Present, enumerated, and no serial port. This used to be reported as
    // "no board found" with advice about cables, which is the wrong repair for
    // a board that is working — and worse, it is advice that cannot succeed,
    // so following it teaches nothing.
    if state == "detached" {
        problems.push(Problem {
            id: "interfaces-detached",
            severity: "warn",
            message: if holders.is_empty() {
                "the board is enumerated but its CDC interfaces are not attached to the kernel, so there is no serial port"
                    .to_string()
            } else {
                format!(
                    "the board is enumerated but its CDC interfaces are not attached to the kernel; {} has the device open",
                    holders.join(", ")
                )
            },
            fix: if holders.is_empty() {
                "yi26 attach"
            } else {
                "close that program (a browser tab counts), then: yi26 attach"
            },
        });
    }

    // -- raw USB access ------------------------------------------------------
    //
    // A warning, not an error: everything up to exp107 works fine without it.
    // It only bites when a browser tries to claim the interface, and the
    // failure there ("Access denied") names nothing that would lead you here.
    let raw_usb = udev::check();
    if raw_usb.present && !raw_usb.open_ok {
        problems.push(Problem {
            id: "no-raw-usb-access",
            severity: "warn",
            message: format!(
                "{} will not open read-write, so WebUSB in a browser cannot claim this board",
                raw_usb.node.as_deref().unwrap_or("the board's USB node")
            ),
            fix: "yi26 udev --install",
        });
    }

    // -- boot drive ---------------------------------------------------------
    let boot_drive = drive::find();
    if bootsel && boot_drive.is_none() {
        problems.push(Problem {
            id: "drive-unmounted",
            severity: "warn",
            message: "the board is in BOOTSEL mode but its drive is not mounted".to_string(),
            fix: "yi26 drive",
        });
    }

    let worst_is_error = problems.iter().any(|p| p.severity == "error");

    if opts.json {
        let problems_json: Vec<String> = problems
            .iter()
            .map(|p| {
                out::obj(&[
                    out::kv_str("id", p.id),
                    out::kv_str("severity", p.severity),
                    out::kv_str("message", &p.message),
                    out::kv_str("fix", p.fix),
                ])
            })
            .collect();

        println!(
            "{}",
            out::obj(&[
                out::kv_str("tool", "yi26"),
                out::kv_str("version", VERSION),
                out::kv_raw(
                    "host",
                    &out::obj(&[
                        out::kv_str("os", os),
                        out::kv_str("arch", std::env::consts::ARCH),
                        out::kv_bool("verified", verified),
                    ])
                ),
                out::kv_raw(
                    "toolchain",
                    &out::obj(&[
                        out::kv_opt("cargo", cargo.as_deref().map(|p| p.to_str().unwrap_or(""))),
                        out::kv_opt("rustup", rustup.as_deref().map(|p| p.to_str().unwrap_or(""))),
                        out::kv_opt(
                            "elf2flash",
                            elf2flash.as_deref().map(|p| p.to_str().unwrap_or(""))
                        ),
                    ])
                ),
                out::kv_raw(
                    "board",
                    &out::obj(&[
                        out::kv_str("state", state),
                        out::kv_raw(
                            "port",
                            &port.as_ref().map(port_json).unwrap_or_else(|| "null".into())
                        ),
                    ])
                ),
                out::kv_raw(
                    "boot_drive",
                    &boot_drive
                        .as_ref()
                        .map(|d| out::obj(&[
                            out::kv_str("path", &d.path.to_string_lossy()),
                            out::kv_opt("info_uf2", d.info.as_deref()),
                        ]))
                        .unwrap_or_else(|| "null".into())
                ),
                out::kv_raw("problems", &out::arr(&problems_json)),
            ])
        );
    } else {
        println!("yi26 doctor {VERSION}");
        println!();
        println!("  host");
        println!(
            "    os          {os} ({})",
            if verified { "verified" } else { "NOT verified — see tools/README.md" }
        );
        println!("  toolchain");
        println!("    cargo       {}", show(&cargo));
        println!("    rustup      {}", show(&rustup));
        println!("    elf2flash   {}", show(&elf2flash));
        println!("  board");
        println!(
            "    state       {}",
            match state {
                "bootsel" => "in BOOTSEL mode — waiting for a .uf2",
                "running" => "running one of these firmwares",
                "detached" => "enumerated, but its interfaces are not the kernel's",
                _ => "not found",
            }
        );
        if !holders.is_empty() {
            println!("    held by     {}", holders.join(", "));
        }
        if let Some(p) = &port {
            println!(
                "    usb         {:04x}:{:04x}  {}",
                p.vid,
                p.pid,
                p.product.as_deref().unwrap_or("(no product string)")
            );
            println!("    port        {}", p.path);
        }
        println!("  boot drive");
        match &boot_drive {
            Some(d) => {
                println!("    path        {}", d.path.display());
                println!("    info        {}", d.info.as_deref().unwrap_or("(none)"));
            }
            None => println!("    path        not mounted"),
        }
        println!();
        if problems.is_empty() {
            println!("  nothing wrong that this tool can see.");
        } else {
            for p in &problems {
                println!("  [{}] {}", p.severity, p.message);
                if !p.fix.is_empty() {
                    println!("         try: {}", p.fix);
                }
            }
        }
    }

    if worst_is_error {
        1
    } else {
        0
    }
}

fn show(p: &Option<PathBuf>) -> String {
    p.as_ref().map(|p| p.display().to_string()).unwrap_or_else(|| "MISSING".to_string())
}

/// Finds an executable on PATH. `which` itself is not guaranteed to exist, and
/// shelling out to it to find out whether we can shell out is silly.
fn which(cmd: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(cmd);
        if is_executable(&candidate) {
            return Some(candidate);
        }
        #[cfg(target_os = "windows")]
        {
            let exe = dir.join(format!("{cmd}.exe"));
            if is_executable(&exe) {
                return Some(exe);
            }
        }
    }
    None
}

fn is_executable(p: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        p.metadata().map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0).unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        p.is_file()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn family_id_gate() {
        let mut good = vec![0u8; 32];
        good[28..32].copy_from_slice(&RP2350_FAMILY.to_le_bytes());
        assert!(check_uf2_family(&good).is_ok());

        // An RP2040 UF2 — the ROM would ignore it in silence, which looks
        // exactly like a board that failed to boot.
        let mut rp2040 = vec![0u8; 32];
        rp2040[28..32].copy_from_slice(&0xe48b_ff56u32.to_le_bytes());
        assert!(check_uf2_family(&rp2040).is_err());

        assert!(check_uf2_family(&[0u8; 4]).is_err());
    }

    #[test]
    fn send_transmits_exactly_what_it_was_given() {
        // No trailing newline, invented or stripped. The firmware receiving
        // this prints a hex dump, and a byte nobody typed showing up in it
        // makes the dump a liar.
        assert_eq!(unescape("hello").unwrap(), b"hello");
        assert_eq!(unescape("").unwrap(), b"");
    }

    #[test]
    fn escapes_reach_the_bytes_a_shell_would_have_eaten() {
        assert_eq!(unescape("a\\nb").unwrap(), b"a\nb");
        assert_eq!(unescape("\\r\\t\\0").unwrap(), vec![b'\r', b'\t', 0]);
        assert_eq!(unescape("\\\\").unwrap(), b"\\");
        assert_eq!(unescape("\\x00\\xff\\x41").unwrap(), vec![0x00, 0xff, 0x41]);
    }

    #[test]
    fn a_bad_escape_is_refused_rather_than_guessed() {
        // Silently sending a literal backslash-q would put a byte on the wire
        // that the caller did not ask for, and they would find out by reading
        // a hex dump. Refusing is the only honest option.
        assert!(unescape("\\q").is_err());
        assert!(unescape("\\").is_err());
        assert!(unescape("\\xZZ").is_err());
        assert!(unescape("\\x4").is_err());
    }

    #[test]
    fn multibyte_text_survives_unescaped() {
        // The payload is bytes, not characters, and UTF-8 must not be
        // mangled on the way through.
        assert_eq!(unescape("é").unwrap(), "é".as_bytes());
    }
}
