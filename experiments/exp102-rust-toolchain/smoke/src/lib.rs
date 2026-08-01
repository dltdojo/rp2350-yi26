//! The only job of this crate is to prove that your machine can compile
//! Rust for the RP2350's Cortex-M33 core (`thumbv8m.main-none-eabihf`).
//!
//! It is a library, not a firmware: there is no entry point, no linker
//! script, and nothing to flash. If `cargo build --target
//! thumbv8m.main-none-eabihf` succeeds here, the cross-compiler and the
//! core library for the target are installed and working — which is all
//! exp102 sets out to show. exp103 turns this into a real program.

#![no_std]
// ^ "This code uses no operating system services." The `none` in the target
//   triple and this attribute are two sides of the same fact — the RP2350
//   runs your code on bare metal, so `std` (files, threads, println!) does
//   not exist there. Only `core` (integers, slices, Option, ...) does.

/// GPIO number of the onboard LED on the Pico 2 (non-W).
/// exp103's blink drives this pin.
pub const LED_PIN: u8 = 25;

/// Half-period of the 1 Hz blink exp103 builds, in milliseconds.
pub const BLINK_HALF_PERIOD_MS: u64 = 500;
