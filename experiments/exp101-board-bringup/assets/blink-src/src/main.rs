//! Minimal LED blink for the Raspberry Pi Pico 2 (RP2350).
//!
//! This is the source of the prebuilt `blink.uf2` shipped one directory up.
//! It is intentionally the smallest possible Embassy program: initialize the
//! chip, take the onboard LED pin (GPIO25, active-high on the Pico 2), and
//! toggle it forever at 1 Hz.
//!
//! Note: this firmware has NO USB function. Once it is running, the board
//! will not show up in `lsusb` at all — that is expected, and exp101's
//! README explains why.

#![no_std]
#![no_main]

use embassy_executor::Spawner;
use embassy_rp::gpio::{Level, Output};
use embassy_time::Timer;
use panic_halt as _;

// Pulls in the RP2350 memory layout and the boot ROM image-definition block.
use rp2350_linker as _;

#[embassy_executor::main]
async fn main(_spawner: Spawner) {
    let p = embassy_rp::init(Default::default());

    // Onboard LED on the Pico 2 (non-W): GPIO25, active-high.
    let mut led = Output::new(p.PIN_25, Level::Low);

    loop {
        led.set_high();
        Timer::after_millis(500).await;
        led.set_low();
        Timer::after_millis(500).await;
    }
}
