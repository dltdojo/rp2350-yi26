//! exp123 — what a host asks a disk, before answering any of it.
//!
//! The board declares a mass-storage interface and then declines every
//! command it receives, printing each one first. Nothing pretends to be a
//! disk; the point is to read the interrogation.
//!
//! # Bulk-Only Transport is three phases and two structures
//!
//! USB mass storage does not have a rich protocol. It has a 31-byte **Command
//! Block Wrapper** going out, an optional data phase, and a 13-byte **Command
//! Status Wrapper** coming back. Inside the CBW sits a SCSI command block —
//! the same SCSI that talks to a hard disk over a cable that has nothing to do
//! with USB.
//!
//! ```text
//!   CBW  'USBC' tag len flags lun cblen  [ 16 bytes of SCSI ]
//!   data (maybe, in whichever direction the flags say)
//!   CSW  'USBS' tag residue status
//! ```
//!
//! That is the whole framing. Everything a USB stick does is those three
//! phases repeated, and this experiment prints the first one.
//!
//! # "Answer nothing" needed defining
//!
//! The plan for this experiment said *answer nothing*, and taken literally
//! that is dangerous rather than minimal. A host whose bulk transfer never
//! completes waits, times out, issues a Bulk-Only Mass Storage Reset, retries,
//! and eventually resets the whole USB device — which takes the CDC interface
//! with it, on a loop, and makes reflashing a matter of catching a gap.
//!
//! Stalling the endpoint would be the specification's answer, and this driver
//! does not offer it: `endpoint_set_stalled` lives on the `Bus`, which
//! `UsbDevice::run()` owns.
//!
//! So the reply here is *well-formed refusal*. The data phase is ended early
//! with a zero-length packet, and the status wrapper says **Command Failed**
//! with the full transfer length as residue. Every phase completes, the host
//! is never left waiting, and it concludes there is no usable medium and stops
//! asking. The commands are still all visible, which is what the experiment
//! is for.
//!
//! # Nothing here is a disk
//!
//! No capacity, no blocks, no sense data. The host will decide this device is
//! broken, and it is right. exp124 starts answering.

#![no_std]
#![no_main]

use core::fmt::Write as _;
use core::sync::atomic::{AtomicU32, Ordering};

use embassy_executor::Spawner;
use embassy_futures::select::{select, Either};
use embassy_rp::bind_interrupts;
use embassy_rp::gpio::{Level, Output};
use embassy_rp::peripherals::USB;
use embassy_rp::usb::{Driver, Endpoint, In, InterruptHandler, Out};
use embassy_time::{Duration, Timer};
use embassy_usb::class::cdc_acm::{CdcAcmClass, ControlChanged, Receiver, Sender, State};
use embassy_usb::driver::{Endpoint as _, EndpointIn, EndpointOut};
use embassy_usb::{Builder, Config as UsbConfig, UsbDevice};
use panic_halt as _;
use rp2350_linker as _;
use static_cell::StaticCell;
use usb_log::log;

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
});

const PACKET: usize = 64;
const IDLE_REPORT: Duration = Duration::from_secs(5);

/// Mass Storage, SCSI transparent command set, Bulk-Only Transport.
///
/// Three numbers, and the last two are what tell the host that the 31-byte
/// wrapper below is what it should send. A different protocol byte would mean
/// a different framing entirely.
const CLASS_MSC: u8 = 0x08;
const SUBCLASS_SCSI: u8 = 0x06;
const PROTOCOL_BOT: u8 = 0x50;

/// `USBC`, little-endian. The first four bytes of every command wrapper.
const CBW_SIGNATURE: u32 = 0x4342_5355;
/// `USBS`. The first four bytes of every status wrapper.
const CSW_SIGNATURE: u32 = 0x5342_5355;

const CBW_LEN: usize = 31;
const CSW_LEN: usize = 13;

/// Bit 7 of `bmCBWFlags`: set means the data phase goes device-to-host.
const CBW_FLAG_IN: u8 = 0x80;

/// `bCSWStatus` values. This firmware only ever sends one of them.
const CSW_COMMAND_FAILED: u8 = 0x01;

static COMMANDS: AtomicU32 = AtomicU32::new(0);

/// The SCSI opcodes a Linux host sends at a USB disk it has just met.
///
/// Named rather than printed as bare numbers, because the sequence is the
/// experiment: the order these arrive in *is* how an operating system decides
/// whether there is a disk there.
fn opcode_name(op: u8) -> &'static str {
    match op {
        0x00 => "TEST UNIT READY",
        0x03 => "REQUEST SENSE",
        0x12 => "INQUIRY",
        0x1a => "MODE SENSE(6)",
        0x1b => "START STOP UNIT",
        0x1e => "PREVENT ALLOW MEDIUM REMOVAL",
        0x23 => "READ FORMAT CAPACITIES",
        0x25 => "READ CAPACITY(10)",
        0x28 => "READ(10)",
        0x2a => "WRITE(10)",
        0x35 => "SYNCHRONIZE CACHE(10)",
        0x5a => "MODE SENSE(10)",
        0x9e => "SERVICE ACTION IN(16)",
        _ => "unknown to this experiment",
    }
}

struct Hex<'a>(&'a [u8]);

impl core::fmt::Display for Hex<'_> {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        for (i, b) in self.0.iter().enumerate() {
            if i > 0 {
                f.write_char(' ')?;
            }
            write!(f, "{:02x}", b)?;
        }
        Ok(())
    }
}

fn le_u32(b: &[u8]) -> u32 {
    u32::from_le_bytes([b[0], b[1], b[2], b[3]])
}

#[embassy_executor::task]
async fn usb_task(mut device: UsbDevice<'static, Driver<'static, USB>>) -> ! {
    device.run().await
}

#[embassy_executor::task]
async fn log_task(sender: Sender<'static, usb_reboot::UsbDriver>) -> ! {
    usb_log::run(sender).await
}

#[embassy_executor::task]
async fn console_task(
    control: ControlChanged<'static>,
    mut receiver: Receiver<'static, usb_reboot::UsbDriver>,
) -> ! {
    let mut buf = [0u8; PACKET];
    loop {
        match select(control.control_changed(), receiver.read_packet(&mut buf)).await {
            Either::First(()) => {
                let rate = receiver.line_coding().data_rate();
                usb_reboot::reboot_if_requested(rate).await;
            }
            Either::Second(_) => {}
        }
    }
}

/// Reads command wrappers, prints them, and refuses them.
#[embassy_executor::task]
async fn storage_task(
    mut read_ep: Endpoint<'static, USB, Out>,
    mut write_ep: Endpoint<'static, USB, In>,
) -> ! {
    let mut buf = [0u8; PACKET];

    loop {
        read_ep.wait_enabled().await;

        loop {
            let n = match read_ep.read(&mut buf).await {
                Ok(n) => n,
                Err(_) => break,
            };

            // Anything that is not a 31-byte wrapper starting with 'USBC' is
            // not a command, and guessing at it would be worse than saying so.
            // A host that has lost phase sends exactly this.
            if n != CBW_LEN || le_u32(&buf[0..4]) != CBW_SIGNATURE {
                log!("not a CBW: {} bytes, {}", n, Hex(&buf[..n.min(8)]));
                continue;
            }

            let tag = le_u32(&buf[4..8]);
            let len = le_u32(&buf[8..12]);
            let flags = buf[12];
            let lun = buf[13];
            let cb_len = (buf[14] & 0x1f) as usize;
            let cb = &buf[15..15 + cb_len.min(16)];
            let to_host = flags & CBW_FLAG_IN != 0;

            let seq = COMMANDS.fetch_add(1, Ordering::Relaxed) + 1;
            log!(
                "cbw #{}: tag {:08x} lun {} {} {} bytes",
                seq,
                tag,
                lun,
                if to_host { "IN " } else { "OUT" },
                len
            );
            log!("   {}  <- {}", Hex(cb), opcode_name(cb[0]));

            // The data phase, ended before it starts. A zero-length packet is
            // a short transfer, which is how a device says "that is all I
            // have" — the host stops waiting and moves to the status phase
            // instead of timing out.
            if len > 0 && to_host {
                if write_ep.write(&[]).await.is_err() {
                    break;
                }
            }
            // For a host-to-device transfer, the bytes are already on their way
            // and something has to take them, or the host waits for an endpoint
            // that never reads. Discarded, deliberately: this experiment has
            // nowhere to put them.
            if len > 0 && !to_host {
                let mut left = len as usize;
                while left > 0 {
                    match read_ep.read(&mut buf).await {
                        Ok(got) => left = left.saturating_sub(got.max(1)),
                        Err(_) => break,
                    }
                }
            }

            // Command Failed, with every byte of the requested transfer
            // reported as residue — "I did none of it" stated precisely rather
            // than by silence.
            let mut csw = [0u8; CSW_LEN];
            csw[0..4].copy_from_slice(&CSW_SIGNATURE.to_le_bytes());
            csw[4..8].copy_from_slice(&tag.to_le_bytes());
            csw[8..12].copy_from_slice(&len.to_le_bytes());
            csw[12] = CSW_COMMAND_FAILED;
            if write_ep.write(&csw).await.is_err() {
                break;
            }
        }
    }
}

#[embassy_executor::task]
async fn idle_task() -> ! {
    loop {
        Timer::after(IDLE_REPORT).await;
        let n = COMMANDS.load(Ordering::Relaxed);
        if n == 0 {
            log!("idle: a disk was declared and nothing has asked it anything yet");
        } else {
            log!("idle: {} commands received, all refused", n);
        }
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let p = embassy_rp::init(Default::default());
    let mut led = Output::new(p.PIN_25, Level::Low);

    let driver = Driver::new(p.USB, Irqs);

    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some("exp123 bot framing");
    config.serial_number = Some("123");
    config.device_class = 0xef;
    config.device_sub_class = 0x02;
    config.device_protocol = 0x01;
    config.composite_with_iads = true;

    static CONFIG_DESCRIPTOR: StaticCell<[u8; 256]> = StaticCell::new();
    static BOS_DESCRIPTOR: StaticCell<[u8; 256]> = StaticCell::new();
    static CONTROL_BUF: StaticCell<[u8; 64]> = StaticCell::new();
    static ACM_STATE: StaticCell<State> = StaticCell::new();

    let mut builder = Builder::new(
        driver,
        config,
        CONFIG_DESCRIPTOR.init([0; 256]),
        BOS_DESCRIPTOR.init([0; 256]),
        &mut [],
        CONTROL_BUF.init([0; 64]),
    );

    let class = CdcAcmClass::new(&mut builder, ACM_STATE.init(State::new()), PACKET as u16);

    // Built by hand, like exp122's vendor interface — `embassy-usb` has no MSC
    // class, which is why the mass-storage track is four experiments and not
    // one. The class, subclass and protocol triple is the entire declaration:
    // everything else about being a disk is behaviour.
    let (read_ep, write_ep) = {
        let mut function = builder.function(CLASS_MSC, SUBCLASS_SCSI, PROTOCOL_BOT);
        let mut interface = function.interface();
        let mut alt = interface.alt_setting(CLASS_MSC, SUBCLASS_SCSI, PROTOCOL_BOT, None);
        let out = alt.endpoint_bulk_out(None, PACKET as u16);
        let in_ = alt.endpoint_bulk_in(None, PACKET as u16);
        (out, in_)
    };

    let usb = builder.build();
    spawner.spawn(usb_task(usb).unwrap());

    let (sender, receiver, control) = class.split_with_control();
    spawner.spawn(log_task(sender).unwrap());
    spawner.spawn(console_task(control, receiver).unwrap());
    spawner.spawn(storage_task(read_ep, write_ep).unwrap());
    spawner.spawn(idle_task().unwrap());

    log!("exp123 up. A disk is declared. Nothing here is a disk.");

    loop {
        led.set_high();
        Timer::after(Duration::from_millis(50)).await;
        led.set_low();
        Timer::after(Duration::from_millis(950)).await;
    }
}
