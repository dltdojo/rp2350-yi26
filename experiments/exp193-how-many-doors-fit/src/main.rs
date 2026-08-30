//! exp193 — how many doors fit.
//!
//! [exp190](../exp190-the-board-that-brings-itself-back/) moved the CDC-ACM
//! bring-up into [`crates/cdc-console`](../../crates/cdc-console/) and proved it
//! on hardware, but only in the shape forty-five experiments here use: a serial
//! port and nothing else. **Twenty-nine experiments put something else on the
//! same port**, and for those the crate had no path at all — it called
//! `builder.build()` itself, so there was nowhere to add an interface.
//!
//! # The claim it was built to test
//!
//! > Components extracted into crates compose on one board, and the wall they
//! > run into is the configuration descriptor — which a host can measure, and
//! > which the board survives hitting.
//!
//! **The second half of that is wrong, and this experiment is how it was
//! found.** The board stopped at five interfaces with 120 of its 256 descriptor
//! bytes still unspent. The wall was somewhere else.
//!
//! # What the wall actually is
//!
//! `embassy-usb` keeps its interface list in a `heapless::Vec` whose capacity is
//! a compile-time setting, `MAX_INTERFACE_COUNT`, **defaulting to 4**. Push a
//! fifth and it asserts, in `Builder::interface`, before anything reaches the
//! bus.
//!
//! Eight experiments here already set that feature — exp148–exp155 and exp161,
//! the network and browser line, each with a comment in its own `Cargo.toml`
//! saying why. **Thirty-two other composite experiments do not**, and fit under
//! four without mentioning it. What none of them can record any more is that
//! `cdc_console::open` spends two of the four before its caller adds anything:
//! the console is a crate now, and a `Cargo.toml` comment in one experiment is
//! the wrong place for a budget the crate spends.
//!
//! So there are two walls, and the run walks towards both:
//!
//! ```text
//!   lane      what stops it                      measured at
//!   narrow    MAX_INTERFACE_COUNT = 4            5 interfaces, 136/256 bytes spent
//!   wide      the descriptor buffer, 256 bytes   8 interfaces would need 268
//! ```
//!
//! `narrow` is embassy-usb as every firmware here has ever built it. `wide` sets
//! `max-interface-count-8` and `max-handler-count-8`, the largest the crate
//! offers, which moves the wall from hid 3 to hid 6 — and only then is the byte
//! count the thing that runs out.
//!
//! # Why a wall at all, rather than "it works"
//!
//! An experiment that only shows a composite device enumerating passes by
//! construction, which is [exp140](../exp140-a-checksum-that-passes/)'s subject.
//! A number that can be walked into is what makes this falsifiable — and it
//! earned that immediately, by refuting the half of the claim above.
//!
//! # The one that can fail in the expensive direction
//!
//! **Declared and enumerated must agree.** A composite bring-up that quietly
//! drops the last interface — a `State` reused, a class constructed after
//! `build()` — produces a board that enumerates, logs, and answers the
//! 1200-baud touch while being wrong. That failure looks like success from the
//! board's side, so the board is not the witness: `verify.py` counts interfaces
//! out of the host's own descriptor bytes and compares them with what the board
//! said it was building.
//!
//! # What is not this experiment's
//!
//! The serial console is [`crates/cdc-console`](../../crates/cdc-console/) and
//! the recovery is [`crates/lifeline`](../../crates/lifeline/) — both walls are
//! panics before USB exists, and the board came back from every one of them in
//! one second with nobody in the room. The HID interfaces carry nothing: they
//! are filler with a twenty-two-byte report descriptor, because what is being
//! measured is the room they take up, not what they could say.

#![no_std]
#![no_main]

use embassy_executor::Spawner;
use embassy_rp::gpio::{Level, Output};
use embassy_time::{Duration, Timer};
use embassy_usb::class::hid::{Config as HidConfig, HidBootProtocol, HidSubclass, HidWriter, State};
use static_cell::StaticCell;

use usb_log::log;

include!(concat!(env!("OUT_DIR"), "/exp193_config.rs"));

/// The defaults, named once — the same three this repository's other
/// lifeline firmwares use.
const LIFELINE: lifeline::Config = lifeline::Config {
    boot_us: lifeline::DEFAULT_BOOT_US,
    run_us: lifeline::DEFAULT_RUN_US,
    escape_after: lifeline::DEFAULT_ESCAPE_AFTER,
};

/// How many HID `State`s are preallocated.
///
/// The walk has to stop being about SRAM before it can be about descriptors, so
/// this is comfortably past where the descriptor budget is expected to run out.
/// `build.rs` refuses a larger `EXP193_HID` against the same number.
const MAX_HID: usize = 12;

/// The smallest report descriptor a host will accept: one vendor-defined usage
/// page, one usage, nothing else.
///
/// Deliberately tiny. A keyboard descriptor is about sixty bytes and lives in
/// the *report* descriptor, which is fetched separately and is not part of the
/// configuration descriptor at all — so a big one would cost this experiment
/// nothing and would only make the filler look like it meant something.
const REPORT: &[u8] = &[
    0x06, 0x00, 0xff, // usage page (vendor defined 0xff00)
    0x09, 0x01, //       usage (1)
    0xa1, 0x01, //       collection (application)
    0x09, 0x01, //         usage (1)
    0x15, 0x00, //         logical minimum (0)
    0x26, 0xff, 0x00, //   logical maximum (255)
    0x75, 0x08, //         report size (8)
    0x95, 0x01, //         report count (1)
    0x81, 0x02, //         input (data, variable, absolute)
    0xc0, //             end collection
];

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    // FIRST, before embassy_rp::init and before any peripheral. If three boots
    // in a row have died before saying they were reachable — which is exactly
    // what the step past the wall does — this hands the board to the ROM
    // bootloader instead of to somebody at a bench.
    let boot = lifeline::begin(LIFELINE);

    let p = embassy_rp::init(Default::default());
    // The LED before anything that can hang, and it is `lifeline`'s own: this
    // firmware's LED has no second meaning to carry, and a copy of the crate's
    // blink here would be free to drift from the one the crate documents.
    spawner.spawn(lifeline::led(Output::new(p.PIN_25, Level::Low), boot).unwrap());
    spawner.spawn(lifeline::keepalive(LIFELINE).unwrap());

    const _: () = assert!(HID <= MAX_HID);

    // The console, and the `Builder` back. Nothing is on the bus yet.
    let mut device = cdc_console::open_composite(
        p.USB,
        cdc_console::Config {
            product: "exp193 how many doors fit",
            serial: "193",
        },
    );

    // The filler. Every one of these costs the same handful of bytes out of the
    // budget the console is already spending 70 of, and the step that does not
    // fit panics inside `HidWriter::new` — before `lifeline::alive`, so it
    // counts towards the escape.
    static STATES: StaticCell<[State; MAX_HID]> = StaticCell::new();
    let states = STATES.init([(); MAX_HID].map(|_| State::new()));
    let mut writers: [Option<HidWriter<'_, cdc_console::UsbDriver, 8>>; MAX_HID] =
        [const { None }; MAX_HID];
    for (n, state) in states.iter_mut().enumerate().take(HID) {
        writers[n] = Some(HidWriter::new(
            device.builder(),
            state,
            HidConfig {
                report_descriptor: REPORT,
                request_handler: None,
                poll_ms: 255,
                max_packet_size: 8,
                hid_subclass: HidSubclass::No,
                hid_boot_protocol: HidBootProtocol::None,
            },
        ));
    }

    device.finish(spawner);

    // **Reachable.** Past here a death is an ordinary crash rather than a boot
    // that never came up, and this boot stops counting towards the escape.
    lifeline::alive(LIFELINE);

    // The facts, on a loop rather than once, because somebody attaching late is
    // the normal case. Two interfaces are the console's; the rest are filler.
    //
    // The board says what it *declared*. It cannot say what the descriptor
    // actually cost — `embassy-usb` keeps that inside `Builder` — and it is the
    // wrong witness anyway: a firmware that dropped an interface would report
    // the number it meant to build. The host counts what arrived.
    loop {
        log!(
            "boot {}, last ended: {:?} at step {} — {} death(s) before it was up",
            boot.count,
            boot.cause,
            boot.step,
            boot.deaths
        );
        log!(
            "EXP193_HID={} lane={}, declaring {} of {} interfaces, {} descriptor bytes",
            HID,
            LANE,
            2 + HID,
            INTERFACE_BUDGET,
            cdc_console::CONFIG_DESCRIPTOR_BYTES
        );
        Timer::after(Duration::from_secs(3)).await;
    }
}
