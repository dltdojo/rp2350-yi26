# exp112-silent-fallback — the fallback that every test passes

This firmware wants to use the hardware TRNG. `Cargo.toml` says so — the
`hardware-rng` feature is on by default. The code says so — a `cfg` picks the
TRNG when that feature is on.

Build it without that feature and it uses a software generator instead. Not an
error, not a warning, not a panic. A different function, chosen at compile
time, doing what looks like the same job.

The experiment is everything that then **fails to notice**.

Needs: any RP2350 board, and the exp102 toolchain.

## The failure class

A build-time guard that selects a security-critical component, where the
failing branch is silent and its output is indistinguishable from the correct
one by inspection. Nothing about it is specific to Rust or to this chip:

- the guard tests the wrong thing, or the flag never reaches the build,
- the fallback runs instead of the intended source,
- everything downstream keeps working, because the fallback's *shape* is
  correct — right size, right type, right-looking bytes,
- and the bug can sit in shipped, public, readable code for years, because
  reading the code tells you what a **default build** would do rather than
  what the artifact in front of you actually does.

This has happened in the field, to shipped cryptographic hardware, with money
attached. It is not a hypothetical, and the details of any one incident matter
less than the shape.

## What does not catch it

**The output.** Below is real output from both builds of this firmware.

```
software: a1 72 35 03 31 86 41 01
hardware: ba 17 a2 be aa d9 ac af
```

**The statistical tests from exp111.** The software generator here is
xorshift32, chosen deliberately because it is *good* at looking random:

```
[software] tests after 960 bits: ones 48.8%  changes 49.0%  (fair coin 50.0%) -> PASS either way
```

Both tests, comfortably passed, by a generator whose entire state is 32 bits
and whose seed is a constant in the source. The `[software]` tag is on every
scored line rather than only in the boot banner, because a terminal attached
after boot would otherwise be reading numbers without knowing which build
produced them — and "PASS" means opposite things depending on the answer.

**The firmware's own banner.** This build prints which generator it selected,
and that line is the least trustworthy thing in the experiment: it proves what
the firmware *prints*, not what it *does*. If the `cfg` on the log line and
the `cfg` on the generator ever drifted apart, nothing would catch it.

**Watching it run.** It enumerates, logs, blinks and responds identically.

## What does catch it

**Rebooting.** A software generator seeded from a constant produces the same
bytes on every boot, of every board, forever:

```
--- boot 1 ---            --- boot 2 ---
bytes #1: a1 72 35 03     bytes #1: a1 72 35 03
bytes #2: b2 60 70 01     bytes #2: b2 60 70 01
bytes #3: d2 aa b1 51     bytes #3: d2 aa b1 51
```

The hardware build, same two boots:

```
--- boot 1 ---            --- boot 2 ---
bytes #1: ba 17 a2 be     bytes #1: a0 7d 6f 89
bytes #2: 85 79 f5 00     bytes #2: 4a b7 2a c2
```

That is free, takes ten seconds, and would have caught it. It is also the one
test nobody runs, because a random number generator that returned the same
value twice is *obviously* broken and therefore not worth checking for.

**Asking the artifact.** The build stamps a marker into the binary, the same
way `crates/usb-reboot` does, and [`audit.sh`](../audit.sh) reads it out of
the `.uf2`:

```console
$ ./audit.sh exp112-silent-fallback

  Random number generator in the built firmware
    state:    software fallback — a deterministic generator, not entropy
    evidence: marker 'yi26-cfg:rng=software' found inside exp112-software.uf2
    risk:     Every value this firmware calls random is reproducible by
              anyone holding the same build. The output passes the
              statistical tests in exp111 and looks correct in a log.
              If anything derived from it were ever used as a key,
              a secret, or a nonce, it would not be one.
    to change: cargo build --release (the default enables hardware-rng), then reflash
    ▲ review this
    ▲ MISMATCH: a default build of this checkout would use
              'hardware', but the .uf2 on disk uses 'software'.
              Reading the source would have told you the wrong answer.
```

That last line is the whole experiment. `audit.sh` reads two independent
sources — what a default build of this checkout *would* select, and what the
`.uf2` on disk actually *did* select — and when they disagree, the artifact
wins.

## The code IS the walkthrough

- [`src/main.rs`](./src/main.rs) — the `cfg` that chooses, the marker that
  records the choice, and a comment on why the log line is not evidence.
- [`../audit.sh`](../audit.sh) — the check itself, in the section on random
  number generators.

## Two ways to do it

```sh
./run.sh      # guided: build both, flash both, reboot both, then audit
./check.sh    # verdict: builds both, and checks the running board
```

## A second footgun, for free

Building the broken variant needs:

```sh
cargo build --release --no-default-features --features auto-reboot
```

`--no-default-features` drops **every** default, not just the one you meant —
here it would also take `auto-reboot` with it, and a firmware built without
that cannot be reflashed over USB. The `--features auto-reboot` puts it back.

That is the same class of mistake as the one being demonstrated: a build flag
whose blast radius is wider than the thing you were thinking about.

## Make it yours

1. Delete the `#[cfg(not(feature = "hardware-rng"))]` branch and the
   `SoftwareRng` struct entirely, then try to build without the feature. It
   fails to compile. **A fallback that does not exist cannot be selected by
   accident** — that is a stronger fix than any check, and it is available
   more often than people assume.
2. Make the two `cfg`s disagree on purpose: have the log line claim `HARDWARE`
   while the generator branch uses software. Nothing complains. Now run
   `audit.sh` and watch the marker still tell the truth, because it is
   generated from the same `cfg!` as the code rather than written by hand.
3. Seed `SoftwareRng` from the flash unique ID instead of a constant. The
   reboot tell disappears — every board now produces its *own* fixed
   sequence — and every statistical test still passes. exp113 is about what
   that seed is worth.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Both builds produce different bytes each boot | You built the same one twice | The variant needs `--no-default-features --features auto-reboot` |
| Board stops accepting `yi26 flash` | `--no-default-features` dropped `auto-reboot` | Hold BOOTSEL, replug, flash the default build |
| `audit.sh` reports the wrong variant | Several `.uf2` files in `target/` | It audits the newest and names the others — rebuild the one you mean |

## Next

**exp113** takes the fix from "Make it yours" step 3 — seed the software
generator from something device-specific — and asks how much that is actually
worth. The answer is measured, by enumeration, on the board itself.
