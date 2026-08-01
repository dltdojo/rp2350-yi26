# exp101 assets

## blink.uf2

Prebuilt firmware for the Raspberry Pi Pico 2 (non-W). Blinks the onboard LED
(GPIO25) at 1 Hz. Contains no USB function.

- **Source:** [`blink-src/`](./blink-src/) in this directory — a minimal
  Rust + Embassy program, part of this repository.
- **License:** Apache-2.0, same as the rest of this repository. No third-party
  binaries are redistributed here.
- **UF2 family:** `0xE48BFF59` (rp2350-arm-s), load address `0x10000000`.

## Rebuilding it

Requires the Rust toolchain from exp102 plus `elf2flash`
(`cargo install elf2flash`):

```sh
cd blink-src
cargo build --release
elf2flash convert -b rp2350 \
    target/thumbv8m.main-none-eabihf/release/exp101-blink ../blink.uf2
```

The checked-in `blink.uf2` is regenerated with exactly these commands whenever
`blink-src/` changes.
