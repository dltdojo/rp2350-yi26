//! Raw USB access — what a browser needs, and what Linux does not give away.
//!
//! Everything else in this tool talks to the board through a serial port or a
//! mounted drive, both of which an ordinary user can already open. The browser
//! experiments do not: WebUSB claims the USB interface directly, which on Linux
//! means read-write access to the device node under `/dev/bus/usb`. That is
//! `root`-only by default, so the first Connect in Chrome fails with *Access
//! denied* and nothing explains why.
//!
//! Two decisions shape this module.
//!
//! **The check is an open, not a file test.** Asking "does the rule file exist?"
//! answers a question nobody has — a rule that exists but does not work is
//! worse than no rule at all, because it sends you looking somewhere else.
//! Opening the device is the same operation the browser performs, so its
//! result is the answer by construction.
//!
//! **The fix runs under one `sudo`.** Installing the rule, reloading, and
//! re-triggering are three privileged steps; run separately they can be three
//! password prompts. They are one `sh -c` here so the password is typed once,
//! and the rule text arrives on stdin rather than through a temporary file
//! that something else could swap out in between.

use std::io::Write;
use std::process::{Command, Stdio};

use nusb::MaybeFuture;

use crate::board::{EXP_PID, EXP_VID};

/// Where the rule goes. The `70-` prefix is not decoration: `uaccess` tags are
/// consumed by systemd's `73-seat-late.rules`, so a rule that sets one has to
/// sort before it.
pub const RULE_PATH: &str = "/etc/udev/rules.d/70-rp2350-yi26.rules";

/// The rule itself.
///
/// `TAG+="uaccess"` hands access to whoever is physically logged in at the
/// seat, through systemd-logind. That is deliberately narrower than the
/// `MODE="0666"` seen in a lot of hobby instructions, which opens the device
/// to every account on the machine including ones that are not sitting at it,
/// and narrower than adding yourself to a group, which persists whether or not
/// you are logged in.
pub fn rule_text() -> String {
    format!(
        "# Installed by `yi26 udev --install` from the rp2350-yi26 experiments.\n\
         #\n\
         # WebUSB claims the board's USB interface directly, which needs read-write\n\
         # access to its /dev/bus/usb node. Without this, Chrome's first Connect\n\
         # fails with \"Access denied\".\n\
         #\n\
         # uaccess grants that to the user physically logged in at this seat, and\n\
         # to nobody else. Delete this file to undo it.\n\
         SUBSYSTEM==\"usb\", ATTR{{idVendor}}==\"{EXP_VID:04x}\", ATTR{{idProduct}}==\"{EXP_PID:04x}\", TAG+=\"uaccess\"\n"
    )
}

/// What `check` found.
pub struct Access {
    /// The board is plugged in and running one of these firmwares.
    pub present: bool,
    /// The device node, when the board is present — `/dev/bus/usb/001/007`.
    pub node: Option<String>,
    /// The device opened read-write. This is the question that matters.
    pub open_ok: bool,
    /// Why it did not open, in the operating system's own words.
    pub error: Option<String>,
    /// A file already exists at [`RULE_PATH`].
    pub rule_installed: bool,
}

/// Tries to open the board the way a browser would.
pub fn check() -> Access {
    let rule_installed = std::path::Path::new(RULE_PATH).exists();

    let Ok(devices) = nusb::list_devices().wait() else {
        return Access {
            present: false,
            node: None,
            open_ok: false,
            error: Some("cannot enumerate USB at all".to_string()),
            rule_installed,
        };
    };

    let Some(info) = devices
        .into_iter()
        .find(|d| d.vendor_id() == EXP_VID && d.product_id() == EXP_PID)
    else {
        return Access {
            present: false,
            node: None,
            open_ok: false,
            error: None,
            rule_installed,
        };
    };

    let node = Some(format!(
        "/dev/bus/usb/{:03}/{:03}",
        info.busnum(),
        info.device_address()
    ));

    match info.open().wait() {
        Ok(_) => Access {
            present: true,
            node,
            open_ok: true,
            error: None,
            rule_installed,
        },
        Err(e) => Access {
            present: true,
            node,
            open_ok: false,
            error: Some(e.to_string()),
            rule_installed,
        },
    }
}

/// The privileged half, as one shell command.
///
/// Kept in one place because it is also what `--explain` prints: the user
/// should be able to read exactly what will run as root before it does, and
/// type it themselves instead if they would rather.
///
/// `udevadm settle` is the last step and it is load-bearing. `trigger`
/// returns as soon as the events are *queued*, not once they have been
/// processed — so without it, the verification that runs immediately
/// afterwards races the ACL it is checking for and reports a failure against
/// a rule that is about to work. That happened on the first real run of this
/// command; the fix is not to retry harder but to wait for the thing that
/// already knows when it has finished.
pub fn install_script() -> String {
    format!(
        "cat > {RULE_PATH} && chmod 0644 {RULE_PATH} && \
         udevadm control --reload && \
         udevadm trigger --subsystem-match=usb --attr-match=idVendor={EXP_VID:04x} && \
         udevadm settle --timeout=10"
    )
}

/// Installs the rule. Asks for the sudo password once; changes nothing else.
pub fn install() -> Result<(), String> {
    if std::env::consts::OS != "linux" {
        return Err(format!(
            "udev is Linux-only; there is nothing to install on {}",
            std::env::consts::OS
        ));
    }

    let mut child = Command::new("sudo")
        .arg("sh")
        .arg("-c")
        .arg(install_script())
        .stdin(Stdio::piped())
        .spawn()
        .map_err(|e| format!("cannot run sudo: {e}"))?;

    child
        .stdin
        .take()
        .ok_or_else(|| "sudo did not accept input".to_string())?
        .write_all(rule_text().as_bytes())
        .map_err(|e| format!("cannot write the rule: {e}"))?;

    let status = child
        .wait()
        .map_err(|e| format!("sudo did not finish: {e}"))?;

    if status.success() {
        Ok(())
    } else {
        Err(format!("sudo exited with {status}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// udev compares `ATTR{idVendor}` against the kernel's own formatting:
    /// four lowercase hex digits, zero-padded. `1209` survives a careless
    /// format string; `0001` does not, and a rule that reads `ATTR{idProduct}
    /// =="1"` matches nothing while looking perfectly reasonable.
    #[test]
    fn rule_uses_the_kernel_s_four_digit_hex() {
        let r = rule_text();
        assert!(r.contains(r#"ATTR{idVendor}=="1209""#), "{r}");
        assert!(r.contains(r#"ATTR{idProduct}=="0001""#), "{r}");
        assert!(r.contains(r#"TAG+="uaccess""#), "{r}");
    }

    /// The rule is written by `cat` reading stdin, so a missing trailing
    /// newline produces a file udev parses one line short.
    #[test]
    fn rule_ends_with_a_newline() {
        assert!(rule_text().ends_with('\n'));
    }

    /// `--explain` prints this for the user to type instead. If it drifts from
    /// what `install` actually runs, the explanation becomes a lie — so both
    /// come from this one function, and this test pins what it must contain.
    #[test]
    fn install_script_covers_every_privileged_step() {
        let s = install_script();
        assert!(s.contains(RULE_PATH), "{s}");
        assert!(s.contains("udevadm control --reload"), "{s}");
        assert!(s.contains("udevadm trigger"), "{s}");
        // Without settle, the verification that follows races the ACL it is
        // checking for. This is not decoration; it is the whole reason the
        // first real run of --install reported a failure against a rule that
        // was working.
        assert!(s.contains("udevadm settle"), "{s}");
    }
}
