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

## Do this, in order

Everything here works from a `.zip` built by `pack.sh` alone. Three firmware
images are in it; two of them are the experiment and they are **designed to be
indistinguishable** until you do the one thing nobody does.

WHAT YOU NEED
  * A Raspberry Pi Pico 2 and a USB data cable. RP2350 only.
  * Ubuntu. `cat`, `stty`, `strings` and `grep` are already there.

1. UNPACK IT, AND ASK THE ARTIFACT BEFORE YOU RUN ANYTHING.

       unzip exp112-silent-fallback.zip
       cd exp112-silent-fallback
       for f in firmware/exp112-hardware.uf2 firmware/exp112-software.uf2; do
           printf '%-32s ' "$(basename $f)"
           strings -a "$f" | grep -o 'yi26-cfg:rng=[a-z]*' | head -1
       done

   Expect each image to name its own generator:

       exp112-hardware.uf2              yi26-cfg:rng=hardware
       exp112-software.uf2              yi26-cfg:rng=software

   Each build stamps into its own binary which generator it selected. **This
   is the only check here that reads the thing that will actually run** rather
   than the source it came from or the log it prints. It costs one command and
   needs nothing but `strings`.

   **There is a third image in `firmware/`, and you should ignore it.**
   `exp112-silent-fallback.uf2` is a by-product: it is whatever `check.sh`
   happened to build last, so its marker says `hardware` or `software`
   depending on nothing you can see. It has the most official-looking name of
   the three and it is the one file here you cannot conclude anything from.
   That is a wart in this experiment's build, recorded rather than hidden,
   and it is a small demonstration of the same lesson: a name is not evidence.

2. FLASH THE SOFTWARE ONE. **[HUMAN STEP]** Hold BOOTSEL, plug in, let go:

       cp firmware/exp112-software.uf2 /media/$USER/RP2350/

3. READ ITS FIRST THREE DRAWS.

       sleep 5
       stty -F /dev/ttyACM0 -icrnl
       timeout 8 cat /dev/ttyACM0

       [      37 ms] bytes #1: a1 72 35 03 31 86 41 01
       [     537 ms] bytes #2: b2 60 70 01 21 e6 a2 a1
       [    1037 ms] bytes #3: d2 aa b1 51 47 cc 90 f9

   Look at them and try to see anything wrong. There is nothing to see. The
   generator is xorshift32, picked because it is *good* at looking random, and
   it passes the statistical tests from [exp111](../exp111-measuring-randomness/)
   comfortably.

4. REBOOT IT AND READ THEM AGAIN. This is the whole experiment, and it takes
   ten seconds.

       stty -F /dev/ttyACM0 1200
       sleep 5
       cp firmware/exp112-software.uf2 /media/$USER/RP2350/
       sleep 6
       stty -F /dev/ttyACM0 -icrnl
       timeout 8 cat /dev/ttyACM0

   **Wait for the drive.** The touch puts the board in its bootloader, but the
   `RP2350` volume takes a second or two to appear and be mounted; copy too
   early and the file goes nowhere, leaving the board sitting in BOOTSEL. If
   that happens, nothing is broken — the drive is there now, so just run the
   `cp` again.

   Expect **the same three lines, byte for byte**:

       [      37 ms] bytes #1: a1 72 35 03 31 86 41 01
       [     537 ms] bytes #2: b2 60 70 01 21 e6 a2 a1
       [    1037 ms] bytes #3: d2 aa b1 51 47 cc 90 f9

   A generator seeded from a constant produces the same bytes on every boot,
   of every board, forever.

5. NOW DO BOTH AGAIN WITH THE HARDWARE BUILD.

       cp firmware/exp112-hardware.uf2 /media/$USER/RP2350/

   ...then steps 3 and 4 unchanged, other than the filename. Expect two boots
   that share nothing:

       boot 1   bytes #1: be b0 0a e5 5b a8 b9 78
       boot 2   bytes #1: 6c a9 35 fe 0d dc bf 7a

6. COUNT WHAT DID NOT CATCH IT. The output looked fine. The statistical tests
   passed. The firmware's own banner said which generator it had — and that
   line is the least trustworthy thing here, because it proves what the
   firmware *prints*, not what it *does*. It enumerated, logged and blinked
   identically.

   Two things caught it, and step 1 was one of them. The other was rebooting,
   which is free, and which nobody does, because a random number generator
   that returns the same value twice is *obviously* broken and therefore not
   worth checking for.

IF IT DOES NOT WORK
  * `stty` prints nothing and never returns — ModemManager. Ctrl-C, wait,
    retry.
  * After step 4's touch there is no `/dev/ttyACM0` and no drive either —
    give it a moment; the board is between two identities.
  * The board is in BOOTSEL and you want it back — copy any `.uf2` from
    `firmware/` onto the drive. That is all reflashing ever is here.

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
