# exp103-embassy-blink — the LED is the toolchain, proven

exp101 proved the hardware chain, exp102 the compiler. This experiment
connects them: **source code you can read becomes a light that blinks.**
Source → ELF → UF2 → boot drive → running firmware, every arrow visible.

Needs: an RP2350 board with a plain LED on a GPIO, and the toolchain from
exp102. The default `PIN_25` is the official Pico 2's LED — one marked line in
`src/main.rs` ports it to another board. See [Boards](../README.md#boards).

## The code IS the walkthrough

Read [`src/main.rs`](./src/main.rs) first — it is ~70 lines, more comment
than code on purpose. Every line carries its own explanation, so the
explanation cannot drift out of sync with the code. This README only covers
the concepts around it.

## Two ways to do it

**Guided (recommended the first time):**

```sh
./run.sh
```

Builds, converts, walks you through the BOOTSEL dance, flashes, and asks the
only judge that matters — your eyes.

**Quick verdict (no board needed):**

```sh
./check.sh
```

Compiles the firmware, converts it, and verifies the UF2 family ID. Flashing
needs a human on the button, so it lives only in `run.sh`.

## What's actually happening (the manual version)

```sh
cargo build --release                                    # 1. source → ELF
elf2flash convert -b rp2350 \
  target/thumbv8m.main-none-eabihf/release/exp103-embassy-blink \
  target/exp103-embassy-blink.uf2                        # 2. ELF → UF2
# 3. unplug → hold BOOTSEL → plug in (exp101's dance)
cp target/exp103-embassy-blink.uf2 /media/$USER/RP2350/  # 4. UF2 → flash
# 5. the drive vanishes — that's success — and the LED blinks
```

## Expected output

Captured from a real Pico 2 on Ubuntu:

```console
$ ./check.sh
PASS  toolchain present (cargo, elf2flash)
PASS  firmware compiles (137776 byte ELF)
PASS  converts to UF2 (9728 bytes)
PASS  UF2 family ID is e48bff59 (rp2350-arm-s)
```

After the copy in `run.sh`, the boot drive vanished within ~2 seconds and
`lsusb` showed no Raspberry Pi device at all — the firmware has no USB
function, exactly as exp101 said it would.

## The three ideas to take away

1. **`async`/`await` maps perfectly onto a microcontroller.** `.await` on a
   timer does not spin the CPU — the task parks, the executor finds nothing
   else to run, and the core literally sleeps until the timer interrupt.
   Blinking at ~0% CPU, with code that reads top-to-bottom. This scales:
   later experiments run many tasks (USB, timers, buttons) on one core, and
   the style stays this readable.

2. **Ownership works on hardware.** `embassy_rp::init` hands you the
   peripherals as values that are *moved*, not shared — after
   `Output::new(led_pin, ...)`, no other code can touch that pin. A whole
   class of "two drivers fighting over one peripheral" bugs becomes a compile
   error.

3. **One line of magic remains, on purpose.** `use rp2350_linker as _;`
   silently provides the memory map and the image-definition block the ROM
   scans for before booting anything (the UF2 family ID check in `check.sh`
   is a cousin of the same idea). A planned experiment opens this box and
   hand-builds both pieces — until then, the magic is labelled, not hidden.

## Make it yours

The real skill is the loop, not the blink. In `src/main.rs`, change both
`500`s to `100`, then:

```sh
./run.sh
```

Same dance, five times the blink. Two things to feel: how fast
edit-compile-flash cycles once the toolchain is in place — and how annoying
the BOOTSEL button is on every single flash. That annoyance is real, it is
why a later experiment teaches firmware to reboot itself into the bootloader,
and it is exactly the pain the exp101 section "But other boards don't need
the button?" promised to fix.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Build fails | Toolchain incomplete | `../exp102-rust-toolchain/check.sh` names the missing piece |
| Copy succeeds but drive stays | UF2 rejected (wrong family?) | `./check.sh` — step 4 verifies the family ID |
| Drive vanished, LED dark | Wrong LED pin for your board | Change the marked line in `src/main.rs` — see [Boards](../README.md#boards) |
| Board gone from lsusb after flash | Nothing — that's correct | exp101, takeaway 3 |

## Next

The blink proves the pipeline but is mute — you cannot ask it anything.
**exp104** gives it a voice over USB serial, with no hardware beyond the cable
already in your hand, and **exp105** uses that same port for the 1200-baud
trick that finally retires the BOOTSEL button.

Logging through a debug probe (`defmt` over RTT) is the other way to make
firmware talk, and it is the better one once you are debugging USB itself. It
stays an optional side track here because it costs a part you may not own —
see [Toolchain](../../README.md#toolchain).
