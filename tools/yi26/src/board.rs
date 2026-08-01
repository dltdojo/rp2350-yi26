//! Finding the board, and talking to it.
//!
//! Two different questions need two different mechanisms, which is why this
//! file has two dependencies rather than one:
//!
//! - A board **running one of these firmwares** appears as a serial port, and
//!   `serialport` reports the USB vendor/product behind each port on every
//!   platform. That single call replaces both `lsusb` and the Linux-only
//!   `/dev/serial/by-id/` directory the shell scripts used.
//! - A board **in BOOTSEL mode** has no serial port at all — it is a mass
//!   storage device. It can only be found by enumerating USB, which is what
//!   `nusb` is for.

use std::time::{Duration, Instant};

use nusb::MaybeFuture;

/// The RP2350 ROM bootloader's USB identity. Burned into the chip, identical
/// on every RP2350 board.
pub const BOOTSEL_VID: u16 = 0x2e8a;
pub const BOOTSEL_PID: u16 = 0x000f;

/// pid.codes' shared test identity, which every firmware in this repository
/// uses. Fine for learning, wrong for a product — `experiments/audit.sh` says
/// so at more length.
pub const EXP_VID: u16 = 0x1209;
pub const EXP_PID: u16 = 0x0001;

/// The manufacturer string these firmwares set. Used only to pick between
/// several devices sharing the test PID, never as the primary test.
pub const MANUFACTURER: &str = "rp2350-yi26";

/// Not a real baud rate — a signal. See `crates/usb-reboot`.
pub const MAGIC_BAUD: u32 = 1200;

/// Any rate that is not [`MAGIC_BAUD`]. Opening a port has to pick one, and
/// picking the magic value by accident would reboot the board we came to read.
pub const SAFE_BAUD: u32 = 115_200;

#[derive(Clone)]
pub struct Port {
    pub path: String,
    pub vid: u16,
    pub pid: u16,
    pub product: Option<String>,
    pub serial: Option<String>,
    pub manufacturer: Option<String>,
}

/// Finds a serial port belonging to a board running one of these firmwares.
///
/// Prefers one whose manufacturer string matches [`MANUFACTURER`], because
/// 1209:0001 is a shared test ID and somebody else's project may be plugged
/// into the same machine.
pub fn find_port() -> Option<Port> {
    let ports = serialport::available_ports().ok()?;
    let mut best: Option<Port> = None;

    for p in ports {
        let serialport::SerialPortType::UsbPort(info) = p.port_type else {
            continue;
        };
        if info.vid != EXP_VID || info.pid != EXP_PID {
            continue;
        }
        let port = Port {
            path: p.port_name,
            vid: info.vid,
            pid: info.pid,
            product: info.product.clone(),
            serial: info.serial_number.clone(),
            manufacturer: info.manufacturer.clone(),
        };
        let ours = port.manufacturer.as_deref() == Some(MANUFACTURER);
        if ours {
            return Some(port);
        }
        best.get_or_insert(port);
    }
    best
}

/// True while a board is sitting in the ROM bootloader.
pub fn in_bootsel() -> bool {
    bootsel_device().is_some()
}

fn bootsel_device() -> Option<(u16, u16)> {
    let devices = nusb::list_devices().wait().ok()?;
    devices
        .into_iter()
        .find(|d| d.vendor_id() == BOOTSEL_VID && d.product_id() == BOOTSEL_PID)
        .map(|d| (d.vendor_id(), d.product_id()))
}

/// Asks a running firmware to reboot into the ROM bootloader, by setting the
/// serial port to 1200 baud.
///
/// The shell version of this had to open the port twice, at two different
/// rates, because `stty` sends nothing when the requested rate is already the
/// current one — so a port that happened to be sitting at 1200 was never
/// touched at all. Here the rate is changed on an already-open port, which is
/// unconditional by construction.
pub fn touch_1200(path: &str) -> Result<(), String> {
    let mut port = serialport::new(path, SAFE_BAUD)
        .timeout(Duration::from_millis(200))
        .open()
        .map_err(|e| format!("cannot open {path}: {e}"))?;

    // Let the firmware's watcher settle on the safe rate first, so the change
    // below is unambiguous.
    std::thread::sleep(Duration::from_millis(200));

    port.set_baud_rate(MAGIC_BAUD)
        .map_err(|e| format!("cannot set 1200 baud on {path}: {e}"))?;

    // Hold the port open while the firmware acts. exp105 learned this the
    // expensive way: the board waits 250 ms before resetting so the control
    // transfer can finish, and closing the port underneath that is how you get
    // a device that is enumerated and dead.
    std::thread::sleep(Duration::from_millis(1000));
    drop(port);
    Ok(())
}

/// Waits for a board to appear in BOOTSEL mode.
pub fn wait_for_bootsel(timeout: Duration) -> bool {
    wait_until(timeout, in_bootsel)
}

/// Waits for a board running one of these firmwares to enumerate.
pub fn wait_for_port(timeout: Duration) -> Option<Port> {
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(p) = find_port() {
            return Some(p);
        }
        if Instant::now() >= deadline {
            return None;
        }
        std::thread::sleep(Duration::from_millis(300));
    }
}

fn wait_until(timeout: Duration, mut f: impl FnMut() -> bool) -> bool {
    let deadline = Instant::now() + timeout;
    loop {
        if f() {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(300));
    }
}
