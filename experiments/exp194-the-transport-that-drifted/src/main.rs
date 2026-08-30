//! exp194 — the transport that drifted.
//!
//! The measurement half of this experiment is [`../drift.sh`](../drift.sh): six
//! firmwares off one accretion chain, asked the same twelve questions, and ten
//! of the twelve answered identically. **This is the other half** — the same
//! twelve questions asked of a firmware that was assembled rather than copied.
//!
//! # The claim
//!
//! > **A transport extracted to a measured specification answers every case the
//! > five correct firmwares answer, including the two the fourteenth got
//! > wrong — and its `src/main.rs` contains none of the deciding.**
//!
//! # Where the decisions are
//!
//! [`crates/ctap-hid`](../../crates/ctap-hid/) holds every judgement about what
//! an arriving packet means, as a pure function taking the clock as an argument.
//! It has **twenty-two host tests**, one per case the hardware suite asks plus
//! the reassembly and fragmentation identities, and `cargo test` runs them on a
//! machine with no board.
//!
//! The loop is the crate's too, and that was the ratchet's doing rather than
//! foresight: this firmware first carried a 97-line `ctaphid_task` — already ten
//! times smaller than what it replaced — and `experiments/duplication.sh` failed
//! it for being a fifteenth one. A loop small enough to feel harmless is exactly
//! the kind that gets copied.
//!
//! What is left here is the one question that was ever this experiment's:
//! **which commands does it answer?** `PING`, and nothing else.
//!
//! # Why the log says almost nothing
//!
//! exp168 paid for this and wrote it down: a paced log line per packet made a
//! 1024-byte `PING` take 1.08 s to reassemble against a 750 ms deadline, and a
//! **legal message failed because the instrument was slower than the subject**.
//! Only initialisation packets are logged here, and the suite that grades this
//! firmware reads `/dev/hidraw`, not the log.

#![no_std]
#![no_main]

use embassy_executor::Spawner;
use embassy_rp::gpio::{Level, Output};
use embassy_time::{Duration, Timer};
use embassy_usb::class::hid::{
    Config as HidConfig, HidBootProtocol, HidReaderWriter, HidSubclass, State,
};
use static_cell::StaticCell;

use ctap_hid::board::Wire as WireOf;
/// The transport, with this firmware's driver filled in.
type Wire = WireOf<'static, cdc_console::UsbDriver>;

use ctap_hid as hid;
use usb_log::log;

const LIFELINE: lifeline::Config = lifeline::Config {
    boot_us: lifeline::DEFAULT_BOOT_US,
    run_us: lifeline::DEFAULT_RUN_US,
    escape_after: lifeline::DEFAULT_ESCAPE_AFTER,
};

/// `0x08` is `CAPABILITY_CBOR` cleared and `NMSG` set: this device speaks the
/// transport and nothing above it, and says so rather than being found out.
/// exp169 measured what claiming otherwise costs.
const CAPABILITIES: u8 = 0x08;

const FIDO_REPORT_DESCRIPTOR: &[u8] = &[
    0x06, 0xD0, 0xF1, // Usage Page (vendor-defined 0xF1D0 — the FIDO Alliance's)
    0x09, 0x01,       // Usage (U2F HID Authenticator Device)
    0xA1, 0x01,       // Collection (Application)
    0x09, 0x20,       //   Usage (Input Report Data)
    0x15, 0x00,       //   Logical Minimum (0)
    0x26, 0xFF, 0x00, //   Logical Maximum (255) — two bytes, because 0xFF in one
                      //                           would be read as -1
    0x75, 0x08,       //   Report Size (8 bits)
    0x95, 0x40,       //   Report Count (64)
    0x81, 0x02,       //   Input (Data, Variable, Absolute)
    0x09, 0x21,       //   Usage (Output Report Data)
    0x15, 0x00,       //   Logical Minimum (0)
    0x26, 0xFF, 0x00, //   Logical Maximum (255)
    0x75, 0x08,       //   Report Size (8 bits)
    0x95, 0x40,       //   Report Count (64)
    0x91, 0x02,       //   Output (Data, Variable, Absolute)
    0xC0,             // End Collection
];

/// What this firmware answers, and nothing else.
///
/// The loop, the reassembly, `INIT`, every error and the expiry that frees a
/// channel are [`crates/ctap-hid`](../../crates/ctap-hid/)'s.
/// [`Wire::next`](ctap_hid::board::Wire::next) returns only what the transport
/// does not own, which leaves this experiment with the one question that was
/// ever its own: which commands does it implement?
///
/// It was ninety-seven lines before the duplication ratchet failed it for being
/// a fifteenth `ctaphid_task`. The ratchet was right — a loop small enough to
/// feel harmless is exactly the kind that gets copied — and this is what it is
/// worth.
#[embassy_executor::task]
async fn answer_task(mut wire: Wire) -> ! {
    let mut buf = [0u8; hid::MAX_MESSAGE];
    loop {
        let (cid, cmd, n) = wire.next(&mut buf).await;
        match cmd {
            // The whole of PING: send back exactly what arrived, which makes it
            // the one command whose correctness is entirely the reassembly and
            // fragmentation the crate does.
            hid::CTAPHID_PING => {
                wire.reply(cid, hid::CTAPHID_PING, &buf[..n]).await;
            }
            other => {
                log!("  {} is not implemented here: ERR_INVALID_CMD", hid::cmd_name(other));
                wire.error(cid, hid::ERR_INVALID_CMD).await;
            }
        }
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let boot = lifeline::begin(LIFELINE);

    let p = embassy_rp::init(Default::default());
    spawner.spawn(lifeline::led(Output::new(p.PIN_25, Level::Low), boot).unwrap());
    spawner.spawn(lifeline::keepalive(LIFELINE).unwrap());

    let mut device = cdc_console::open_composite(
        p.USB,
        cdc_console::Config {
            product: "exp194 the transport that drifted",
            serial: "194",
        },
    );

    static HID_STATE: StaticCell<State> = StaticCell::new();
    let hid_class = HidReaderWriter::new(
        device.builder(),
        HID_STATE.init(State::new()),
        HidConfig {
            report_descriptor: FIDO_REPORT_DESCRIPTOR,
            request_handler: None,
            // 5 ms. A security key is asked for one thing at a time, and this
            // is what every firmware on this road uses.
            poll_ms: 5,
            max_packet_size: hid::PACKET as u16,
            hid_subclass: HidSubclass::No,
            hid_boot_protocol: HidBootProtocol::None,
        },
    );

    device.finish(spawner);
    lifeline::alive(LIFELINE);

    let (reader, writer) = hid_class.split();
    spawner.spawn(answer_task(Wire::new(reader, writer, CAPABILITIES)).unwrap());

    loop {
        log!(
            "boot {}, transport from crates/ctap-hid, timeout {} ms, max {} bytes",
            boot.count,
            hid::TRANSACTION_TIMEOUT_MS,
            hid::MAX_MESSAGE
        );
        Timer::after(Duration::from_secs(5)).await;
    }
}
