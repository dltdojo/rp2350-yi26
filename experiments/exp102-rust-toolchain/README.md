# exp102-rust-toolchain — can this machine build RP2350 firmware?

exp101 proved the hardware chain. This experiment proves the software chain:
**your machine can cross-compile Rust for the RP2350's Cortex-M33 core.**
The proof is a successful build — no board is needed today, and nothing is
flashed.

Everything installs into your home directory on **stable** Rust — no nightly,
and the scripts never use sudo (one step may ask *you* to apt-install the C
toolchain).

## The four pieces

| Piece | What it is | Installed by |
| --- | --- | --- |
| `rustup` | Rust's installer/version manager | official script from [rustup.rs](https://rustup.rs) |
| target `thumbv8m.main-none-eabihf` | the core library pre-built for Cortex-M33 | `rustup target add` |
| `cc` (build-essential) | C linker cargo needs for host tools | `sudo apt install build-essential` |
| `elf2flash` | converts cargo's ELF output into the UF2 the boot drive eats | `cargo install elf2flash` |

## Two ways to do it

**Guided (recommended the first time):**

```sh
./run.sh
```

Installs each missing piece with your confirmation, skips what is already
there, and explains what each piece is for. Safe to re-run.

**Quick verdict:**

```sh
./check.sh
```

Non-interactive, installs nothing, exit code 0/1.

## What's actually happening (the manual version)

```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh   # 1. Rust itself
rustup target add thumbv8m.main-none-eabihf                      # 2. Cortex-M33 target
sudo apt install build-essential                                 # 3. C linker
cargo install elf2flash                                          # 4. ELF→UF2 converter
cd smoke && cargo build --target thumbv8m.main-none-eabihf       # 5. the proof
```

`smoke/` is a deliberately trivial, zero-dependency `no_std` library — if it
compiles for the target, the toolchain works. That is the entire experiment.

## Expected output

Captured from a real setup on Ubuntu (versions will drift forward):

```console
$ ./check.sh
PASS  rustup installed
PASS  rustc available (rustc 1.94.1 (e408947bf 2026-03-25))
PASS  target thumbv8m.main-none-eabihf installed
PASS  C linker (cc) present
PASS  elf2flash installed
PASS  smoke crate cross-compiles for thumbv8m.main-none-eabihf
```

## The three ideas to take away

1. **Cross-compilation is the normal mode of embedded work.** The compiler
   runs on your fast x86 machine and emits code for a CPU that could never
   run a compiler. A "target" in Rust is just the standard libraries
   pre-built for that other CPU — `rustup target add` is a download, not a
   different compiler.

2. **Read the target triple like a sentence.**
   `thumbv8m.main` – `none` – `eabihf`: Thumb instruction set of Armv8-M
   mainline (the Cortex-M33) / running on **no operating system** / hard-float
   calling convention. That `none` has consequences: no files, no threads, no
   `println!` — the `std` library assumes an OS, so bare-metal code uses
   `#![no_std]` and gets only `core`. exp103 makes this concrete.

3. **A compiler is not a firmware pipeline — yet.** Today's proof compiled a
   *library*: no entry point, no memory layout, nothing bootable, no `.uf2`.
   The gap between "code compiles for Cortex-M33" and "the chip boots it" is
   real, and closing it is exactly exp103.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `rustc: command not found` right after installing | current shell predates the install | `source ~/.cargo/env` or open a new terminal |
| `cargo install elf2flash` fails with `linker 'cc' not found` | no C toolchain | `sudo apt install build-essential` |
| `can't find crate for 'core'` when building | target not installed | `rustup target add thumbv8m.main-none-eabihf` |
| smoke build works but is instant / "nothing happened" | that's success — libraries build quietly | `./check.sh` for the explicit verdict |

## Next

**exp103** — write the smallest real firmware (a 1 Hz blink with Embassy),
walk through every line, build it, convert it with `elf2flash`, and copy it
onto the boot drive from exp101. The LED turning on is the whole toolchain,
proven end to end — and you get to watch the vanishing-drive act exp101
promised.
