//! Finding the RP2350 boot drive.
//!
//! The shell version asked `lsblk` for a partition labelled `RP2350` and then
//! `udisksctl` to mount it. This looks for the drive a different way: any
//! mounted filesystem containing `INFO_UF2.TXT`. That file is part of the UF2
//! bootloader convention and the ROM always writes it, so it identifies the
//! drive by what it *is* rather than by what it is called — and it is the same
//! test on every operating system, where mount paths and volume labels are
//! not.
//!
//! Mounting, when the system has not done it already, remains
//! platform-specific. On Linux that is `udisksctl`, and this shells out to it
//! rather than reimplementing unprivileged mounting.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// The file the RP2350 ROM puts on its boot drive.
const MARKER: &str = "INFO_UF2.TXT";

pub struct BootDrive {
    pub path: PathBuf,
    /// First line of `INFO_UF2.TXT`, e.g. "UF2 Bootloader v1.0". Useful in a
    /// report because it comes from the board rather than from us.
    pub info: Option<String>,
}

/// Returns the boot drive if one is mounted.
pub fn find() -> Option<BootDrive> {
    candidate_mounts()
        .into_iter()
        .find(|p| p.join(MARKER).is_file())
        .map(|path| {
            let info = std::fs::read_to_string(path.join(MARKER))
                .ok()
                .and_then(|s| s.lines().next().map(|l| l.trim().to_string()));
            BootDrive { path, info }
        })
}

/// Returns the boot drive, mounting it first if the system has not, and
/// waiting for it to turn up.
///
/// The waiting is the point. A board entering BOOTSEL mode does not produce a
/// mountable drive instantly — the kernel has to enumerate the mass storage
/// device, read its partition table, and let udev publish it, and a desktop
/// may then mount it on its own a moment later. Asking once is a race that
/// passes on a warm cache and fails on a cold one. It failed here on the first
/// run of this command, exactly as it had failed once already in the shell
/// version this replaces.
pub fn find_or_mount() -> Result<BootDrive, String> {
    let deadline = Instant::now() + Duration::from_secs(15);
    let mut last_err = "no filesystem with INFO_UF2.TXT appeared".to_string();

    loop {
        if let Some(d) = find() {
            return Ok(d);
        }
        match mount() {
            Ok(()) => {
                if let Some(d) = find() {
                    return Ok(d);
                }
            }
            Err(e) => last_err = e,
        }
        if Instant::now() >= deadline {
            return Err(last_err);
        }
        std::thread::sleep(Duration::from_millis(500));
    }
}

#[cfg(target_os = "linux")]
fn candidate_mounts() -> Vec<PathBuf> {
    // /proc/mounts rather than a `mount` or `lsblk` subprocess: no parsing of
    // human-facing output, and no dependency on either being installed.
    let Ok(text) = std::fs::read_to_string("/proc/mounts") else {
        return Vec::new();
    };
    text.lines()
        .filter_map(|line| line.split_whitespace().nth(1))
        .map(unescape_mount_path)
        .map(PathBuf::from)
        .collect()
}

/// /proc/mounts escapes spaces and a few other characters in octal. Removable
/// media routinely has a space in its label, so this is not a corner case.
#[cfg(target_os = "linux")]
fn unescape_mount_path(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\\' && i + 3 < bytes.len() {
            let oct = &s[i + 1..i + 4];
            if let Ok(v) = u8::from_str_radix(oct, 8) {
                out.push(v as char);
                i += 4;
                continue;
            }
        }
        out.push(bytes[i] as char);
        i += 1;
    }
    out
}

#[cfg(target_os = "macos")]
fn candidate_mounts() -> Vec<PathBuf> {
    read_dir_paths(Path::new("/Volumes"))
}

#[cfg(target_os = "windows")]
fn candidate_mounts() -> Vec<PathBuf> {
    (b'A'..=b'Z')
        .map(|c| PathBuf::from(format!("{}:\\", c as char)))
        .collect()
}

#[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
fn candidate_mounts() -> Vec<PathBuf> {
    read_dir_paths(Path::new("/media"))
}

#[allow(dead_code)]
fn read_dir_paths(dir: &Path) -> Vec<PathBuf> {
    std::fs::read_dir(dir)
        .map(|entries| entries.filter_map(|e| e.ok()).map(|e| e.path()).collect())
        .unwrap_or_default()
}

#[cfg(target_os = "linux")]
fn mount() -> Result<(), String> {
    // /dev/disk/by-label/RP2350 instead of parsing `lsblk` output: udev
    // publishes it, and a symlink either exists or does not.
    let by_label = Path::new("/dev/disk/by-label/RP2350");
    if !by_label.exists() {
        return Err("no RP2350 partition — is the board in BOOTSEL mode?".to_string());
    }
    let out = std::process::Command::new("udisksctl")
        .args(["mount", "-b", "/dev/disk/by-label/RP2350"])
        .output()
        .map_err(|e| format!("cannot run udisksctl ({e}) — install udisks2, or mount manually"))?;
    if out.status.success() {
        return Ok(());
    }
    let msg = String::from_utf8_lossy(&out.stderr);
    // Already mounted is not a failure; the caller is about to look anyway.
    if msg.contains("AlreadyMounted") {
        return Ok(());
    }
    Err(format!("udisksctl failed: {}", msg.trim()))
}

#[cfg(not(target_os = "linux"))]
fn mount() -> Result<(), String> {
    Err("this system normally mounts removable drives automatically; \
         if the RP2350 drive is not showing up, mount it by hand and re-run"
        .to_string())
}

#[cfg(test)]
mod tests {
    #[cfg(target_os = "linux")]
    #[test]
    fn octal_escapes_in_mount_paths() {
        use super::unescape_mount_path;
        assert_eq!(unescape_mount_path("/media/me/RP2350"), "/media/me/RP2350");
        assert_eq!(unescape_mount_path(r"/media/me/RP\0402350"), "/media/me/RP 2350");
    }
}
