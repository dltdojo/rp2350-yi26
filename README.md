# rp2350-yi26

USB experiments on the Raspberry Pi Pico 2 / RP2350.

A scratchpad for exploring the RP2350's USB controller — device-side classes,
host mode, and the surrounding bring-up work — using embedded Rust.

> **Status:** early. The repository is currently scaffolding only (license,
> `.gitignore`, and this README). Experiment code is not committed yet, so the
> layout and commands below describe the intended shape of the project rather
> than something you can build today.

## Hardware

Target is the [RP2350](https://www.raspberrypi.com/products/rp2350/), the
microcontroller on the Raspberry Pi Pico 2:

- Dual core, switchable between Arm Cortex-M33 and RISC-V Hazard3 cores
- 520 KB on-chip SRAM
- USB 1.1 controller supporting both **device** and **host** roles
- 3 PIO blocks / 12 state machines
- Security features: Arm TrustZone-M, signed boot, OTP

Boards that should work: Pico 2, Pico 2 W, and other RP2350A/RP2350B
(QFN-60 / QFN-80) designs. USB host experiments generally need external VBUS
supply and a USB A breakout rather than the board's own micro-B/USB-C port.

## Scope

Things this repo is meant to poke at:

- USB device classes — CDC-ACM serial, HID, and raw bulk endpoints
- USB host mode on the RP2350's controller
- Enumeration, descriptors, and control-transfer edge cases
- BOOTSEL / UF2 behaviour and `picotool` interaction
- Comparing the same experiment across the Cortex-M33 and Hazard3 cores

## Toolchain

Embedded Rust, `no_std`. The relevant crates in this space are
[`rp235x-hal`](https://github.com/rp-rs/rp-hal) for a bare-metal HAL, or
[`embassy-rp`](https://github.com/embassy-rs/embassy) with `embassy-usb` for an
async stack.

Rust targets, depending on which core you build for:

```sh
# Arm Cortex-M33
rustup target add thumbv8m.main-none-eabihf

# RISC-V Hazard3
rustup target add riscv32imac-unknown-none-elf
```

## Flashing

Either drag-and-drop a UF2 onto the mass-storage device exposed while holding
BOOTSEL at power-on, or use
[`picotool`](https://github.com/raspberrypi/picotool), which understands the
RP2350's UF2 family IDs:

```sh
picotool load -x firmware.uf2
```

For debugging over SWD — worthwhile here, since USB experiments tend to break
the USB serial you would otherwise print over — use a Raspberry Pi Debug Probe
with [`probe-rs`](https://probe.rs):

```sh
probe-rs run --chip RP235x firmware.elf
```

## References

- [RP2350 datasheet](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf)
- [Raspberry Pi Pico 2 datasheet](https://datasheets.raspberrypi.com/pico/pico-2-datasheet.pdf)
- [rp-hal](https://github.com/rp-rs/rp-hal) — Rust HAL for RP2040 / RP235x
- [Embassy](https://embassy.dev) — async embedded framework, includes `embassy-usb`
- [USB 2.0 specification](https://www.usb.org/document-library/usb-20-specification)

## License

Apache-2.0. See [LICENSE](LICENSE).
