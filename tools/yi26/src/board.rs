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

/// Vendor-specific interface class. USB for "no promise about behaviour", and
/// therefore the one class no operating system driver claims — see exp122.
pub const VENDOR_CLASS: u8 = 0xFF;

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
    let mut seen: Option<Port> = None;

    loop {
        if let Some(p) = find_port() {
            if openable(&p.path) {
                return Some(p);
            }
            // The node exists and will not open yet. On Linux that is udev
            // still working: the device file appears first and the `uaccess`
            // tag that makes it yours arrives a moment later. Keep the port so
            // that timing out still reports something true.
            seen = Some(p);
        }
        if Instant::now() >= deadline {
            return seen;
        }
        std::thread::sleep(Duration::from_millis(300));
    }
}

/// Can this port actually be opened, by us, right now?
///
/// Answered by opening it, because nothing weaker is the same question.
/// Permission on a serial device comes from udev's `uaccess` tag, which is an
/// ACL rather than the mode bits — so a file whose metadata reads `0660
/// root:root` may be perfectly openable, and inspecting the metadata would say
/// the opposite.
///
/// The cost is one open/close, which asserts and drops DTR. That is visible to
/// a firmware watching the control line, and it is the price of not reporting
/// success before success is true: `flash` used to announce "running at
/// /dev/ttyACM0" the instant the node appeared, and the next command in the
/// same script failed with `Permission denied`.
fn openable(path: &str) -> bool {
    serialport::new(path, SAFE_BAUD)
        .timeout(Duration::from_millis(50))
        .open()
        .is_ok()
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

// ---------------------------------------------------------------------------
// Raw-USB paths, for when the kernel's serial driver is not in the way — or
// not there at all.

/// The CDC class request that carries the line coding, and the seven-byte
/// payload it expects. Straight out of the USB CDC specification.
const SET_LINE_CODING: u8 = 0x20;

/// Detaches the kernel driver from this board's interfaces.
///
/// Exists because of a measured Chrome behaviour: on Linux, WebUSB's
/// `claimInterface` does **not** detach `cdc_acm`, so a page that wants the
/// CDC interfaces gets `NetworkError: Unable to claim interface` and no
/// explanation. The operating system is perfectly willing — `detach` here and
/// `claim` in the browser both succeed once the driver is out of the way.
///
/// The cost is stated plainly by [`touch_1200_raw`]: with the driver gone
/// there is no `/dev/ttyACM0`, so anything that finds the board through a
/// serial port stops finding it. That is why the reboot touch has a second
/// implementation rather than a warning in a README.
pub fn detach_kernel_driver() -> Result<Vec<u8>, String> {
    let dev = open_exp_device()?;
    let mut done = Vec::new();
    // Interface numbers are not assumed. A composite firmware that grows a
    // function moves them, and detaching the wrong one silently does nothing.
    for n in cdc_interface_numbers()? {
        match dev.detach_kernel_driver(n) {
            Ok(()) => done.push(n),
            // Already detached is the desired state, not a failure.
            //
            // `cdc_acm` binds the CDC pair together, so detaching the control
            // interface takes the data interface with it and the second call
            // finds nothing to detach. The kernel reports ENODATA, which nusb
            // does not map to a specific kind, so the message is what
            // distinguishes "nothing to do" from a real failure. Matching on
            // text is not lovely; being wrong in the other direction would
            // mean reporting success for a detach that did not happen.
            Err(e)
                if e.kind() == nusb::ErrorKind::NotFound
                    || e.to_string().contains("no kernel driver attached") =>
            {
                done.push(n)
            }
            Err(e) => return Err(format!("cannot detach interface {n}: {e}")),
        }
    }
    Ok(done)
}

/// Gives the interfaces back to the kernel, restoring `/dev/ttyACM0`.
pub fn attach_kernel_driver() -> Result<Vec<u8>, String> {
    let dev = open_exp_device()?;
    let mut done = Vec::new();
    for n in cdc_interface_numbers()? {
        match dev.attach_kernel_driver(n) {
            Ok(()) => done.push(n),
            // Already attached is the desired state, not a failure — the same
            // rule detach applies to NotFound, and it matters here because
            // cdc_acm binds the CDC pair together: attaching the control
            // interface brings the data interface with it, so the second call
            // always reports Busy on a two-interface device.
            Err(e) if e.kind() == nusb::ErrorKind::Busy => done.push(n),
            Err(e) => return Err(format!("cannot attach interface {n}: {e}")),
        }
    }
    Ok(done)
}

/// The 1200-baud reboot, over a control transfer instead of a serial port.
///
/// [`touch_1200`] needs `/dev/ttyACM0`, which exists only while the kernel's
/// `cdc_acm` driver holds the interface. Detach that driver so a browser can
/// use the device — which exp116 requires — and the board becomes impossible
/// to reflash without the BOOTSEL button.
///
/// This sends the same `SET_LINE_CODING` the serial driver would have sent,
/// straight down the control pipe. The firmware cannot tell the difference:
/// `crates/usb-reboot` reads the line coding, not the driver that set it.
pub fn touch_1200_raw() -> Result<(), String> {
    let dev = open_exp_device()?;
    let iface = *cdc_interface_numbers()?
        .first()
        .ok_or("no CDC control interface on this device")?;

    let coding = |rate: u32| {
        let mut b = [0u8; 7];
        b[..4].copy_from_slice(&rate.to_le_bytes());
        b[4] = 0; // 1 stop bit
        b[5] = 0; // no parity
        b[6] = 8; // 8 data bits
        b
    };

    // Bounce through a safe rate first, for the reason `--explain` gives about
    // the shell version: a device already sitting at 1200 would otherwise be
    // told nothing, and hear nothing.
    let send = |rate: u32| -> Result<(), String> {
        dev.control_out(
            nusb::transfer::ControlOut {
                control_type: nusb::transfer::ControlType::Class,
                recipient: nusb::transfer::Recipient::Interface,
                request: SET_LINE_CODING,
                value: 0,
                index: iface as u16,
                data: &coding(rate),
            },
            Duration::from_millis(500),
        )
        .wait()
        .map(|_| ())
        .map_err(|e| {
            // EBUSY here means something else owns the interface — in
            // practice a browser tab that claimed it. Saying "hold BOOTSEL"
            // would send someone to the button when closing a tab is enough,
            // and this repository has spent enough of the user's patience on
            // BOOTSEL presses that were not necessary.
            // `TransferError` has no Busy variant and no `kind()`; EBUSY
            // arrives as `unknown (errno 16)`. Matching the text is not
            // lovely, and it is better than sending someone to the BOOTSEL
            // button when closing a browser tab is the actual fix.
            if e.to_string().contains("errno 16") {
                "the interface is held by something else — close any browser tab \
                 connected to the board, then try again"
                    .to_string()
            } else {
                format!("SET_LINE_CODING at {rate} failed: {e}")
            }
        })
    };

    send(SAFE_BAUD)?;
    std::thread::sleep(Duration::from_millis(200));
    // The board resets shortly after acknowledging this one, so a transfer
    // error here is success wearing a disguise.
    let _ = send(MAGIC_BAUD);
    std::thread::sleep(Duration::from_millis(1000));
    Ok(())
}

/// Whether the board is on the USB bus at all, regardless of serial ports.
///
/// `find_port` answers a narrower question than it looks like it does. It asks
/// "is there a serial port", and a board whose CDC interfaces have been taken
/// from the kernel — which is exactly what `yi26 detach` does, and what exp116
/// requires — has none. Reporting that as "no board found" sent at least one
/// person looking for a bad cable while the board sat there enumerated.
pub fn exp_device_present() -> bool {
    nusb::list_devices()
        .wait()
        .map(|mut l| l.any(|d| d.vendor_id() == EXP_VID && d.product_id() == EXP_PID))
        .unwrap_or(false)
}

/// Who, if anyone, has the raw USB device open.
///
/// Linux only, and empty everywhere else — the question only arises where
/// `detach` does. Reads `/proc/*/fd`, which resolves for processes owned by
/// the same user; a browser holding the interfaces is one of those, and it is
/// the case worth naming.
pub fn usbfs_holders() -> Vec<String> {
    #[cfg(not(target_os = "linux"))]
    {
        Vec::new()
    }

    #[cfg(target_os = "linux")]
    {
        let Ok(devices) = nusb::list_devices().wait() else {
            return Vec::new();
        };
        let Some(info) = devices.into_iter().find(|d| d.vendor_id() == EXP_VID && d.product_id() == EXP_PID)
        else {
            return Vec::new();
        };
        let node = format!(
            "/dev/bus/usb/{:03}/{:03}",
            info.busnum(),
            info.device_address()
        );

        let mut found = Vec::new();
        let Ok(entries) = std::fs::read_dir("/proc") else {
            return found;
        };
        for entry in entries.flatten() {
            let name = entry.file_name();
            let Some(pid) = name.to_str().filter(|s| s.bytes().all(|b| b.is_ascii_digit())) else {
                continue;
            };
            let Ok(fds) = std::fs::read_dir(format!("/proc/{pid}/fd")) else {
                continue; // another user's process, or it exited mid-scan
            };
            for fd in fds.flatten() {
                let points_at_the_board = std::fs::read_link(fd.path())
                    .map(|t| t == std::path::Path::new(&node))
                    .unwrap_or(false);
                if !points_at_the_board {
                    continue;
                }
                let comm = std::fs::read_to_string(format!("/proc/{pid}/comm"))
                    .map(|s| s.trim().to_string())
                    .unwrap_or_else(|_| "?".into());
                let entry = format!("{comm} (pid {pid})");
                if !found.contains(&entry) {
                    found.push(entry);
                }
                break;
            }
        }
        found
    }
}

/// Writes to a vendor-specific interface's bulk OUT endpoint and reads what
/// comes back on its IN endpoint.
///
/// The interface and both endpoints are found by walking the descriptors —
/// class `0xFF`, then the bulk pair on its first alternate setting — because
/// exp121 moved every number on this device once already and will again.
///
/// No `detach_kernel_driver` anywhere in here, and that is the experiment. A
/// vendor-specific interface has no class driver to displace, so claiming it
/// costs nothing and takes nothing away: the CDC pair stays with the kernel
/// and `/dev/ttyACM0` stays where it is while this runs.
pub fn vendor_echo(payload: &[u8], timeout: Duration) -> Result<Vec<u8>, String> {
    let info = nusb::list_devices()
        .wait()
        .map_err(|e| format!("cannot enumerate USB: {e}"))?
        .find(|d| d.vendor_id() == EXP_VID && d.product_id() == EXP_PID)
        .ok_or("no board found on USB")?;

    let mut iface_num = None;
    let (mut ep_out, mut ep_in) = (None, None);
    for i in info.interfaces() {
        if i.class() != VENDOR_CLASS {
            continue;
        }
        iface_num = Some(i.interface_number());
        break;
    }
    let iface_num = iface_num.ok_or(
        "this firmware has no vendor-specific interface — flash exp122, or check `yi26 port`",
    )?;

    let dev = info.open().wait().map_err(|e| {
        format!("cannot open the device: {e} — try `yi26 udev --install`")
    })?;
    let iface = dev
        .claim_interface(iface_num)
        .wait()
        .map_err(|e| format!("cannot claim vendor interface {iface_num}: {e}"))?;

    for ep in iface.descriptors().next().ok_or("no alternate setting")?.endpoints() {
        if ep.transfer_type() != nusb::descriptors::TransferType::Bulk {
            continue;
        }
        if ep.direction() == nusb::transfer::Direction::Out && ep_out.is_none() {
            ep_out = Some(ep.address());
        }
        if ep.direction() == nusb::transfer::Direction::In && ep_in.is_none() {
            ep_in = Some(ep.address());
        }
    }
    let ep_out = ep_out.ok_or("the vendor interface has no bulk OUT endpoint")?;
    let ep_in = ep_in.ok_or("the vendor interface has no bulk IN endpoint")?;

    let mut writer = iface
        .endpoint::<nusb::transfer::Bulk, nusb::transfer::Out>(ep_out)
        .map_err(|e| format!("cannot open bulk OUT {ep_out:#04x}: {e}"))?;
    let mut reader = iface
        .endpoint::<nusb::transfer::Bulk, nusb::transfer::In>(ep_in)
        .map_err(|e| format!("cannot open bulk IN {ep_in:#04x}: {e}"))?;

    // The IN endpoint is armed *before* the write goes out. The firmware
    // answers within microseconds of receiving, and a reply that arrives
    // before anyone is waiting for it is a reply the device has to hold — or,
    // on a less forgiving stack, drop. Ordering the two this way costs nothing
    // and removes the race entirely.
    let want = reader.max_packet_size();
    reader.submit(nusb::transfer::Buffer::new(want));

    let sent = writer.transfer_blocking(nusb::transfer::Buffer::from(payload), timeout);
    sent.status.map_err(|e| format!("write failed: {e}"))?;

    let got = reader.wait_next_complete(timeout).ok_or(
        "no reply within the timeout — the firmware took the bytes and sent nothing back",
    )?;
    got.status.map_err(|e| format!("read failed: {e}"))?;
    Ok(got.buffer[..got.actual_len].to_vec())
}

fn open_exp_device() -> Result<nusb::Device, String> {
    nusb::list_devices()
        .wait()
        .map_err(|e| format!("cannot enumerate USB: {e}"))?
        .find(|d| d.vendor_id() == EXP_VID && d.product_id() == EXP_PID)
        .ok_or_else(|| format!("no {EXP_VID:04x}:{EXP_PID:04x} device on USB"))?
        .open()
        .wait()
        .map_err(|e| format!("cannot open the device: {e} — try `yi26 udev --install`"))
}

/// The CDC Communications interface first, then CDC Data.
fn cdc_interface_numbers() -> Result<Vec<u8>, String> {
    let info = nusb::list_devices()
        .wait()
        .map_err(|e| format!("cannot enumerate USB: {e}"))?
        .find(|d| d.vendor_id() == EXP_VID && d.product_id() == EXP_PID)
        .ok_or("board not found")?;
    let mut control = Vec::new();
    let mut data = Vec::new();
    for i in info.interfaces() {
        match i.class() {
            0x02 => control.push(i.interface_number()),
            0x0a => data.push(i.interface_number()),
            _ => {}
        }
    }
    control.extend(data);
    Ok(control)
}
