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

## Do this, in order

This one is different from every other experiment's walkthrough: there is no
board, no firmware, and nothing to flash. What you are proving is that **this
machine can turn source into something an RP2350 would run**. Everything below
works from a `.zip` built by `pack.sh` alone.

WHAT YOU NEED
  * Ubuntu, a network connection, and about ten minutes the first time.
  * `sudo` for exactly one of the five steps, and nothing else.
  * No board. Do not plug anything in; there is nothing here to plug in.

1. RUST ITSELF. Skip if `rustup --version` already answers.

       curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
       source "$HOME/.cargo/env"

   Check it:

       rustup --version && rustc --version

   Expect two lines, e.g. `rustup 1.29.0 (28d1352db 2026-03-05)` and
   `rustc 1.94.1 (e408947bf 2026-03-25)`. Newer is fine — everything here
   builds on stable and nothing pins a compiler version.

2. THE CORTEX-M33 TARGET. This is the standard library, pre-built for the
   processor inside an RP2350. Without it `cargo build --target` has nothing
   to link against.

       rustup target add thumbv8m.main-none-eabihf

   Check it:

       rustup target list --installed | grep thumbv8m

   Expect: `thumbv8m.main-none-eabihf`

3. A C LINKER. Cargo needs one for the tools it builds to run on *this*
   machine, not for the firmware.

       sudo apt install build-essential

   Check it:

       cc --version | head -1

   Expect a line naming a compiler, e.g. `cc (Ubuntu 13.3.0-6ubuntu2~24.04.1)
   13.3.0`.

4. THE UF2 CONVERTER. Cargo emits an ELF; the RP2350's boot drive eats UF2.

       cargo install elf2flash

   Check it:

       elf2flash --version

   Expect: `elf2flash 0.1.0` or newer.

5. THE PROOF. Cross-compile something for the target. If this works, the four
   pieces above are talking to each other, which is the whole experiment.

       cargo new --lib /tmp/smoke-rp2350 && cd /tmp/smoke-rp2350
       cat > src/lib.rs <<'RS'
       #![no_std]
       pub fn add(a: u32, b: u32) -> u32 { a + b }
       RS
       cargo build --target thumbv8m.main-none-eabihf

   Expect a line ending `Finished \`dev\` profile [unoptimized + debuginfo]
   target(s) in ...`. No warnings, no linker errors.

   The repository has the same thing as `exp102-rust-toolchain/smoke/` — a
   deliberately trivial, zero-dependency `no_std` library. It is not in this
   zip because a zip carries no buildable source, and `cargo new` gets you an
   identical one in a second.

       cd - && rm -rf /tmp/smoke-rp2350        # tidy up

6. NOW GET THE REPOSITORY. That is what you just built the tools for, and
   every other experiment assumes a full checkout rather than a copied-out
   directory.

       git clone https://github.com/dltdojo/rp2350-yi26.git
       cd rp2350-yi26/experiments/exp102-rust-toolchain && ./check.sh

   Expect six `PASS` lines and exit 0 — the same five pieces, checked by the
   repository's own script instead of by hand.

IF IT DOES NOT WORK
  * `rustc: command not found` right after installing rustup — the installer
    edits your shell profile and the shell you are in has not read it.
    `source "$HOME/.cargo/env"`, or open a new terminal.
  * `linker \`cc\` not found` — step 3 was skipped. It is easy to skip because
    the error mentions a linker and the thing to install is called
    `build-essential`.
  * `error: toolchain ... does not support target` — step 2 was skipped, or
    the target name has a typo in it. It is long and it is `eabihf`, not
    `eabi`.

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
