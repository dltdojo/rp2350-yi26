# rp2350-yi26

USB experiments on the Raspberry Pi Pico 2 / RP2350, written in **Rust** with
the **[Embassy](https://embassy.dev)** async embedded framework.

A scratchpad for exploring the RP2350's USB controller — device classes,
enumeration behaviour, and the surrounding bring-up work. Rust + Embassy is the
only stack used here: no C/C++ Pico SDK, no TinyUSB, and no blocking HAL.

> **Status:** early. The first experiment is in — see
> [experiments/](./experiments/). Later sections of this README still describe
> the intended shape of the project rather than committed code.

## Getting started

Clone, plug in your RP2350 board, and run the first experiment — no Rust
toolchain needed yet:

```sh
cd experiments/exp101-board-bringup
./run.sh
```

Every experiment is driven the same way: `run.sh` is the interactive
walkthrough, `check.sh` the quick non-interactive verdict. The
[experiments index](./experiments/README.md) lists them in order.

The scripts target Ubuntu and say so up front on any other platform — along
with the recommended path: hand the experiment's scripts and README to an AI
assistant and port them to your OS. See
[Platform](./experiments/README.md#platform).

## Hardware

Target is the [RP2350](https://www.raspberrypi.com/products/rp2350/), the
microcontroller on the Raspberry Pi Pico 2:

- Dual core, switchable between Arm Cortex-M33 and RISC-V Hazard3 cores
- 520 KB on-chip SRAM
- USB 1.1 controller supporting both **device** and **host** roles
- 3 PIO blocks / 12 state machines
- Security features: Arm TrustZone-M, signed boot, OTP

The experiments run on **any RP2350 board** — the official Raspberry Pi Pico 2
or a third-party design. Almost everything they touch is chip-level: BOOTSEL,
the UF2 boot drive, and the USB controller are all in the RP2350's own ROM and
silicon. Only the LED's GPIO and the package feature (`rp235xa` vs `rp235xb`)
are board-specific, and both are one-line changes — see
[Boards](./experiments/README.md#boards). Verification here is on an official
Pico 2 (non-W). USB host experiments generally need external VBUS supply and a
USB A breakout rather than the board's own micro-B/USB-C port.

## Why Rust

The firmware is `no_std` Rust — no operating system, no heap, linked directly
against the chip's startup code. What that buys for USB work specifically:

- **Memory safety without a garbage collector.** USB descriptor parsing and
  endpoint buffer handling are exactly the places where C firmware tends to
  scribble past a buffer. The borrow checker rules that class of bug out at
  compile time, at no runtime cost.
- **Ownership over peripherals.** Peripheral singletons are moved, not shared
  by convention, so two pieces of code cannot accidentally drive the same
  endpoint or pin.
- **Typestate for hardware.** Misconfiguration — reading a pin configured as
  output, using an uninitialised peripheral — becomes a type error instead of
  a silent runtime failure.
- **`Result`-based error handling.** No forgotten error codes on control
  transfers.

## Why Embassy

[Embassy](https://embassy.dev) is an async/await framework for embedded Rust.
Instead of an RTOS with one preallocated stack per thread, each task is an
`async fn` that the compiler lowers into a state machine; the executor drives
them from a single stack and puts the core to sleep when every task is
awaiting. Concurrency is statically allocated and known at compile time.

This fits USB unusually well. A USB device is a pile of concurrent, mostly
idle, interrupt-driven state machines — the control pipe, each class interface,
each endpoint — and `await` expresses "wait for the next SETUP packet" or
"wait for this bulk transfer to complete" directly, rather than as a hand-rolled
state machine in an interrupt handler.

The crates in play:

| Crate | Role |
| --- | --- |
| `embassy-executor` | Async task executor; `#[embassy_executor::main]` and `#[task]` |
| `embassy-rp` | HAL for RP2040 / RP235x — GPIO, USB, PIO, DMA, clocks |
| `embassy-usb` | USB device stack: descriptor builder, control pipe, classes |
| `embassy-sync` | `no_std` channels, mutexes, signals for inter-task comms |
| `embassy-time` | Timers and `Timer::after()`, backed by the RP2350 TIMER block |
| `embassy-futures` | Combinators such as `select` and `join` |

`embassy-usb` ships the class implementations these experiments build on —
CDC-ACM, HID, MIDI, CDC-NCM — plus a `Builder` for assembling descriptors and
an escape hatch for raw endpoints when a stock class is not the point.

Two things to know going in:

- **Which core.** `embassy-rp` targets the Cortex-M33 on RP2350 first; RISC-V
  Hazard3 support is newer and less exercised. Start on Arm.
- **Device, not host.** `embassy-usb` is a device-side stack. The RP2350's
  controller does support host mode, but there is no mature Embassy host stack,
  so host experiments here are exploratory and may need to drive the registers
  through `embassy-rp` directly.

## Shape of a program

An Embassy application binds the USB interrupt to the HAL's handler, takes the
peripherals, and spawns tasks:

```rust
#![no_std]
#![no_main]

use embassy_executor::Spawner;
use embassy_rp::bind_interrupts;
use embassy_rp::peripherals::USB;
use embassy_rp::usb::{Driver, InterruptHandler};

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
});

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let p = embassy_rp::init(Default::default());
    let driver = Driver::new(p.USB, Irqs);

    // Build the USB device from `driver`, spawn its `run()` loop as a task,
    // then spawn whatever class tasks the experiment needs.
}
```

The `usb_serial`, `usb_hid_keyboard`, and `usb_raw` examples in the
[`embassy-rp` examples directory](https://github.com/embassy-rs/embassy/tree/main/examples/rp23)
are the reference points for the RP2350.

## Scope

Things this repo is meant to poke at:

- USB device classes — CDC-ACM serial, HID, and raw bulk endpoints
- Enumeration, descriptors, and control-transfer edge cases
- Composite devices, and where `embassy-usb`'s builder gets awkward
- Async patterns: `select` across endpoints, backpressure via `embassy-sync`
  channels, what happens when a task starves the USB `run()` loop
- USB host mode on the RP2350's controller, as far as the ecosystem allows
- BOOTSEL / UF2 behaviour and `picotool` interaction
- Running the same experiment on the Hazard3 core once support matures

## Toolchain

```sh
# Arm Cortex-M33 — the primary target
rustup target add thumbv8m.main-none-eabihf

# RISC-V Hazard3 — secondary, support is less mature
rustup target add riscv32imac-unknown-none-elf
```

Everything builds on **stable** Rust — no nightly. Each experiment pins its
dependency versions and commits its `Cargo.lock`, so a learner's build is
reproducible rather than a moving target; [exp102](./experiments/exp102-rust-toolchain/)
installs the toolchain and proves it works.

The firmware's own output goes over **USB serial** ([exp104](./experiments/exp104-usb-serial/)),
not RTT — that keeps the early track to one USB cable and nothing else to buy.
`defmt` over RTT is better once you are debugging USB itself, but it needs a
debug probe, so it is an optional side track rather than the default.

## Flashing

The default path needs no tools beyond the compiler: convert the ELF to UF2
and copy it onto the boot drive the ROM exposes while BOOTSEL is held.
[exp101](./experiments/exp101-board-bringup/) meets that drive;
[exp103](./experiments/exp103-embassy-blink/) uses it.

```sh
elf2flash convert -b rp2350 target/thumbv8m.main-none-eabihf/release/NAME out.uf2
cp out.uf2 /media/$USER/RP2350/
```

[`picotool`](https://github.com/raspberrypi/picotool) does the same job and
more (`picotool load -x firmware.uf2`), and a Raspberry Pi Debug Probe over SWD
(`probe-rs run --chip RP235x firmware.elf`) skips the bootloader entirely — both
are useful, neither is required.

## Announcements

Posts written about this project for social media are kept under
[`docs/announcements/`](./docs/announcements/), one dated file per post, so
what was said publicly stays on the record next to the work it describes.
They are a log rather than documentation — the experiments' own READMEs are
what is kept current.

## References

- [Embassy documentation](https://embassy.dev/book/) — the Embassy book
- [Embassy repository](https://github.com/embassy-rs/embassy) — includes `rp23` examples
- [The Embedded Rust Book](https://docs.rust-embedded.org/book/)
- [`embassy-usb` on docs.rs](https://docs.rs/embassy-usb)
- [`embassy-rp` on docs.rs](https://docs.rs/embassy-rp)
- [RP2350 datasheet](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf)
- [Raspberry Pi Pico 2 datasheet](https://datasheets.raspberrypi.com/pico/pico-2-datasheet.pdf)
- [USB 2.0 specification](https://www.usb.org/document-library/usb-20-specification)

## License

Apache-2.0. See [LICENSE](LICENSE).
