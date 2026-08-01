//! exp103 — the smallest real firmware: blink the Pico 2's LED at 1 Hz.
//!
//! Every line below carries its own explanation; this file IS the code
//! walkthrough, so it cannot drift out of sync with the code. The README
//! covers the concepts and the build/flash flow; ./run.sh drives them.

// `std` — files, threads, println! — assumes an operating system underneath.
// There is none on this chip (the `none` in thumbv8m.main-none-eabihf, as
// exp102 spelled out), so we opt out and get `core` only.
#![no_std]
// A normal `fn main()` is *called by* the OS's startup code. No OS, so no
// caller — we opt out of that too. Embassy's macro below provides the real
// entry point instead.
#![no_main]

// Spawner can launch additional async tasks. The blink needs none, but the
// entry-point macro hands us one anyway — the `_` prefix says "unused, on
// purpose".
use embassy_executor::Spawner;
// Output = a GPIO pin configured as a push-pull output; Level = High/Low.
use embassy_rp::gpio::{Level, Output};
// The async timer. Awaiting it is what makes this "blink" rather than "burn
// a busy-loop" — see the loop below.
use embassy_time::Timer;

// A firmware must decide what a panic does — there is no OS to catch it.
// This crate's answer is the simplest one: halt the CPU in a quiet loop.
// The `as _` idiom means "link this crate for its side effect (the panic
// handler it registers); we call nothing from it by name".
use panic_halt as _;

// ── The one magic line ─────────────────────────────────────────────────────
// This crate silently provides two things every bootable RP2350 image needs:
//   1. the memory map — where flash and RAM live, so the linker can place code;
//   2. the image-definition block — bytes the ROM bootloader (the same one
//      that ran the exp101 boot drive) scans for to decide "this is a real
//      Arm firmware, boot it".
// We are deliberately NOT explaining these further today; a planned
// experiment opens this box and builds both pieces by hand.
use rp2350_linker as _;

// This attribute macro generates the actual reset-time entry point: it sets
// up the Embassy executor and runs our `async fn main` as its first task.
#[embassy_executor::main]
async fn main(_spawner: Spawner) {
    // Take ownership of the chip's peripherals — Rust's move semantics mean
    // no other code can now touch the pins we hold. Default config = run the
    // chip at its stock 150 MHz from the crystal.
    let p = embassy_rp::init(Default::default());

    // GPIO 25 is wired to the onboard LED on the Pico 2 (non-W; the W routes
    // its LED through the wireless chip instead — this is why exp103 needs
    // the non-W board). Drive it as an output, starting low = LED off.
    let mut led = Output::new(p.PIN_25, Level::Low);

    loop {
        led.set_high(); // LED on

        // `.await` is the heart of the experiment. It does NOT spin the CPU
        // for 500 ms — it parks this task with the timer hardware armed, and
        // with nothing else to run, the executor puts the core to sleep
        // until the timer interrupt fires. Blinking at ~0 % CPU.
        Timer::after_millis(500).await;

        led.set_low(); // LED off
        Timer::after_millis(500).await;

        // 500 ms on + 500 ms off = the 1 Hz blink this repo has been
        // promising since exp102's smoke crate declared these constants.
    }
}
