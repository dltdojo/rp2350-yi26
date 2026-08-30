# What belongs to an experiment

[`the-board-is-the-loop.md`](./the-board-is-the-loop.md) asked why exp156 took
seven rounds instead of two, and answered it with the cost of a slow loop. This
document asks a question that only appears once a repository has ninety-two
experiments in it:

> **Why does debugging a new experiment keep meaning debugging something the
> experiment was never asking about?**

The answer is a design decision that was right for sixty experiments and stopped
being right. It is written down here because reversing it silently would make
the tree inconsistent in a way nobody could see, and because the reversal has to
be a ratchet rather than a rewrite: ninety-two experiments cannot be retrofitted
when each would cost a board run.

---

## The decision, and what it bought

Every experiment here owns its `src/main.rs`. One experiment, one self-contained
source, readable start to finish without opening anything else, and reproducible
without wondering which version of a shared thing it was built against. That is
not an accident and it is not laziness — it is the property that makes an
experiment usable as evidence.

It worked. exp101 through roughly exp160 are readable on their own, and a reader
who wants to know what exp125 did opens one file.

---

## What it cost, from the tree's own record

Three bills, all already written into the source:

- **exp174 shipped with exp173's USB serial.** The string came across with the
  source when exp174 was derived from exp173, and nothing was looking. Nobody
  noticed until exp177 needed to tell two boards apart and could not — `yi26
  port` and `lib.sh`'s `exp_running` both key on that string, so two firmwares
  were indistinguishable to every script in the repository. The comment is still
  at the site, and `docs-check.sh` now asserts the serial matches the directory.
- **exp160 lost the end of its report** to `usb-log`'s sixteen-deep queue, which
  drops the newest line when full. **exp162 lost it a second time**, by pacing
  inside a `match` whose arms are expressions. exp163's `report()` carries the
  note.
- **exp189 records meeting exp173's subject** — a client that sends a field
  nothing else sends — "for the second time in one afternoon".
- **exp152's `Cargo.toml` explained the wrong number for months.** Its comment
  said the firmware declares four interfaces; it declares five. The comment came
  across from exp151 with the dependency line and was never updated, and the
  file says so itself: *"it was inherited from exp151 and never updated. `lsusb`
  says five."*

None of these is a bug in an experiment's subject. Each is a bug in the part of
the firmware that was never what the experiment was asking about, carried
forward by copying, and paid for again.

---

## The size of it, counted

`./duplication.sh` groups every top-level function by name — in `*/src/*.rs`,
`*/*.py` and `*/*.sh` — and reports how many experiments define it and how many
textually distinct versions exist between them.

| function | in experiments | distinct versions | avg lines |
| --- | --- | --- | --- |
| `console_task` | 17 | 14 | 50 |
| `idle_task` | 17 | 14 | 18 |
| `ctaphid_task` | 14 | **13** | 493 |
| `get_info` | 13 | 7 | 35 |
| `storage_task` | 12 | 7 | 183 |
| `parse_make_credential` | 12 | 6 | 118 |

**22,629 of the 55,110 lines of firmware source here live inside a function that
some other experiment also defines.** Forty-one per cent.

*(As of exp189's port, 21,526. The first time this number has gone down.)*

And the firmware was never the whole of it. The detector read only Rust until
exp194 went looking for a CTAP-HID client and found seven copies of one that
nothing here could see. Counting the host side too:

| | duplicated functions | lines in copies |
| --- | --- | --- |
| `rs` — firmware | 64 | 22,386 |
| `py` — drivers and verifiers | 30 | **5,950** |
| `sh` — run, drop, check | 2 | 67 |

The shell number is small because shell functions are short, not because they
are not copied: `sh:flash` is in five experiments in three versions, and this
session put it in two of them. The threshold had to come down from 12 lines to
8 before any of it was visible at all — a number tuned to Rust hid the whole of
the shell side.

`ctaphid_task` is the shape of the problem drawn out. Sorted by experiment
number, its length is:

```
exp168 110 → 169 → 241 → 333 → 451 → 451 → 531 → 567
                                          ↘ exp184 424      a fork from an older point
                      exp185 516 → 669 → 694 → 791 → exp189 959
```

It is not a shared component that grew. It is fourteen forks of one, and one of
them (exp184) branched from a state before the two experiments above it, so
anything fixed in between is simply not there. exp189's `src/main.rs` is 2,896
lines; 959 of them are that one function; its `verify.py` has twelve assertions,
and not one of them is about how a CTAP-HID transaction is assembled.

---

## The rule

> **This code changed. Would this experiment's claim change?**
>
> No → it is not this experiment's, and it belongs in `crates/`.

It has a checkable approximation, which matters more than the principle:

> **An experiment's scope is what its `check.sh` and `verify.py` assert on.**

Code no assertion depends on is not the subject. exp190's thirteen live
assertions never mention a USB descriptor, so the CDC bring-up was not exp190's
— it is now [`crates/cdc-console`](../crates/cdc-console/). exp189's twelve
assertions never mention transaction assembly, so 959 lines of it are not
exp189's either.

---

## The objection, and the answer

Extraction appears to trade away the thing the original decision bought:
reproducibility. A shared crate changes under an experiment whose recording was
made before the change, and the recording no longer describes code that exists.

The answer is that **duplication never preserved reproducibility. It preserved
staleness.** exp124 passing today is not evidence that its claim still holds; it
is evidence that nobody has re-asked. When the same bug lives in twelve copies
of `storage_task`, twelve experiments' claims are simultaneously in doubt and
none of them will ever say so. With one crate, a regression makes every
dependent experiment's `check.sh` speak at once.

What genuinely needs protecting is a different thing: **the reproducibility of a
past run**, and its carrier is a commit, not a duplicated file. Until this
document, no `capture.txt` recorded which tree produced it. `capture_header` in
`lib.sh` now writes the commit and whether the working tree was dirty as the
first line of every recording, so "which recordings predate this fix" has an
answer.

---

## What extraction costs, stated plainly

- **A bug in a crate is wrong about every firmware built after it**, including
  ones whose captures were recorded earlier and still read as passing. This is
  the real price. It is paid by: recording the commit in every capture (above),
  requiring that a crate change be verified on hardware by at least one
  experiment, and requiring that every dependent experiment still compile.
- **An experiment stops being readable on its own.** The mitigation is that the
  narrative moves with the code. `crates/cdc-console` carries the count of what
  its twenty-two lines cost, because that sentence is worth as much as the
  code. Extracting `ctaphid_task` will be ten times harder for exactly this
  reason: its comments are fourteen experiments' accumulated reasoning.
- **Board-only crates cannot be host-tested.** The repository already answers
  this by splitting the decidable part out: `log-policy` and `log-ring` have
  tests, `usb-log` cannot; `lifeline`'s rule is tested on a host, `lifeline`'s
  `board.rs` is not. New extractions follow the same split — the arithmetic
  where `cargo test` can reach it, the I/O shell as thin as it can be made.

---

## How it is enforced

A rule nobody checks decays. `lifeline_check` exists because two lines nobody
notices is exactly that, and this is a bigger rule.

1. **`duplication.sh --baseline`** records what exists today: 53 duplicated
   functions. Grandfathered, not forgiven.
2. **`duplication.sh --check`** fails when any function gains a copy, or when a
   newly duplicated function appears. `docs-check.sh` runs it, so it fires on
   every push, needs no board and no toolchain.
3. **The baseline may only shrink.** Extract something, re-run `--baseline`, and
   the number goes down and cannot go back up.

The ratchet is the whole mechanism. It does not ask anyone to fix ninety-two
experiments; it asks that the ninety-third not add to them.

---

## What to extract, in order

Priority is the measurement, not taste.

| # | what | now | why it is first |
| --- | --- | --- | --- |
| 1 | ~~CTAP-HID transport~~ → [`crates/ctap-hid`](../crates/ctap-hid/) | **done, exp194** | 384 lines of deciding with 22 host tests, 141 lines of loop, and an experiment left with 17. The fourteen copies are grandfathered; what exists now is what the *next* CTAP experiment is built on |
| 2 | MSC/SCSI + FAT12 glue → `crates/msc-disk` | 12 copies, 7 versions, 262 lines | `crates/fat12` exists and is tested; what is missing is the layer between it and USB |
| 3 | CDC command console → `cdc-console`'s second phase | 17 copies, 14 versions | The crate exists and now hands back the `Builder`; what is still missing is handing back a *reader*, for the firmwares that take commands |
| 4 | ~~`blink_task` / `heartbeat`~~ | **withdrawn — see below** | The 33 name-matches are one candidate, and it needs a person |

### The fourth entry was withdrawn, and why is worth more than it was

`blink_task` and `heartbeat` are defined in 33 experiments, and this table said
the work was pure adoption because `lifeline::led` already exists. Sorting the
33 by what they actually are:

| | | |
| --- | --- | --- |
| **1** | eligible — a plain LED on a firmware already using `lifeline` | exp188 |
| 11 | **the LED already means something else** — `STOPPED`, `BUSY`, *press me* | `lifeline::led`'s own doc says these keep their own |
| 20 | would have to **add** `lifeline` | arms a watchdog, replaces the panic handler, adds the bootloader escape |
| 1 | **not an LED at all** — it logs `alive N` every two seconds | exp183 |

The third row is the one that settles it. Adding `lifeline` to a firmware is not
a cosmetic change, and several of those twenty — exp162, exp163, exp164 — kill
core 0 or hang on purpose to measure a wall. A watchdog that reboots them is a
change to *what they measure*.

And the one remaining candidate is `PRESENCE=2`: re-verifying it needs a finger.

**The number 33 came from grepping a function name**, which is the limitation
written two sections below as a known gap in `duplication.sh` — met here from
the planning side rather than the measuring side, an hour after writing it down.
A priority table built on the detector's output inherits the detector's blind
spots. What the detector is good for is *finding* candidates; what it cannot do
is tell you whether they are the same thing.

**Do not extract ahead of a caller.** `crates/cdc-console` deliberately has no
method for handing the `Builder` back to a composite firmware, because the
seventeen experiments that would want one are not being rewritten and no new one
has asked yet. An API shaped for a caller that does not exist is an API nobody
has been able to catch being wrong, which is
[exp140](../experiments/exp140-a-checksum-that-passes/)'s subject. The first
real caller decides the shape, and verifies it on hardware in the same round.

---

## Measured, 2026-08-30

The second application, on exp193 — the first firmware built from crates rather
than from the previous experiment:

- It introduced **no duplicated function**; `duplication.sh --check` passes with
  the baseline unchanged. Its periodic reporting is inside `main`, which every
  experiment is entitled to its own of.
- It needed `cdc-console` to hand back the `Builder`, so the composite path was
  written for a caller that existed, and verified on hardware in the same round.
- **It refuted the crate's own documentation.** `CONFIG_DESCRIPTOR_BYTES` was
  described as the wall; the board stopped at five interfaces with 120 of those
  256 bytes free, because `embassy-usb`'s `MAX_INTERFACE_COUNT` defaults to 4
  and a serial console spends 2. Raising it to 8 moves the wall to the byte
  count, at 268 of 256.
- Both walls are a panic before USB exists. `lifeline` put the board in its
  bootloader in **one second** from each, drive presented, and the script that
  was already running reflashed it. Nobody was in the room.

And the first, on exp190:

- `lifeline::led` replaced a line-for-line copy of itself that exp190 was
  carrying, along with the `AtomicBool` duplicating `lifeline::is_alive()`.
- `crates/cdc-console` replaced the twenty-two-line CDC bring-up. exp190's
  `src/main.rs` lost 38 lines net.
- `lib.sh`'s `usb_check` reads the interfaces out of `src/main.rs` to rule on
  what `USB_IFACE` claims, so the extraction would have made exp190's honest
  `cdc` read as a lie. The pattern now names both spellings rather than being
  relaxed until it always matches. Verified: the old pattern fails on exp190 and
  nothing else, the new one passes all seventy-six declaring experiments, and no
  experiment's verdict moved.
- exp190's own `check.sh` caught the second consequence by itself: the "LED
  before the USB stack" assertion anchored on `Driver::new`, which had moved. It
  failed before the anchor was updated. The assertion did not change.
- `./drop.sh` on the Ubuntu board: four weights dropped, 13/13 live assertions
  pass with the new descriptors, and every arm was flashed through the 1200-baud
  touch — which verifies that `auto-reboot` forwards correctly through
  `exp190 → cdc-console → usb-reboot` rather than being unified back on by
  Cargo.

## Measured again, 2026-08-30 — exp194

The extraction the priority table had been holding for a caller, done the way
the table said to do it.

- **The measurement came first.** Six firmwares off the chain were asked twelve
  questions where CTAP-HID says what the right answer is. Ten of twelve were
  answered identically — the chain drifted in size from 110 lines to 959 and
  almost not at all in behaviour, which is not what the accretion picture
  predicts. The two exceptions are both exp189's, and one of them refuses the
  broadcast INIT that is a client's only way to recover.
- **So the crate is not a fork tidied up.** It is the behaviour five firmwares
  agreed on and the specification requires — a thing that could only be written
  after the table existed.
- **It has 22 host tests**, because `feed` takes the clock as a `u64` rather
  than reaching for `Instant`. Same split as `log-policy` against `usb-log`.
- **The ratchet caught the author.** exp194's first firmware carried a 97-line
  `ctaphid_task` — ten times smaller than what it replaced — and
  `duplication.sh` failed it for being a fifteenth one. It was right: a loop
  small enough to feel harmless is exactly the kind that gets copied. The loop
  moved into the crate and the experiment kept 17 lines.
- **The host side was duplicated too, and nothing could see it.**
  `duplication.sh` reads only Rust; seven experiments each grew their own
  `ctaphid.py`, 238 to 689 lines, six textually different. That client is now
  [`tools/ctaphid/`](../tools/ctaphid/). **The detector has a blind spot the
  width of every Python and shell script in the tree.**

## Measured a third time, 2026-08-30 — exp189's port

The first time an extraction removed a copy rather than adding a crate beside
one, and the first time it fixed something.

- **Both defects exp194 measured are gone by construction.** `bad-cid` and
  `busy-recovers` are `spec` on the ported firmware; nobody has to remember.
- **A second instance of one of them was found on the way**, in a different code
  path the twelve-case suite could not reach: exp189 refused a broadcast `INIT`
  for the whole of a wait for a person, which the default build makes thirty
  seconds long. Reaching it needed a command that waits, and
  `EXP189_SELECTION=1` with a four-second timeout is one with no side effects —
  so it was measured with nobody in the room.
- **And a drift nobody had asked about**: exp189's own transaction timeout was
  1500 ms where CTAP-HID names 750. The port takes the crate's.
- **The crate grew `Wire::wait_for` for a caller that existed**, which is the
  rule holding for the third round running.
- **The port was mechanical and the compiler did the checking.** Seventy
  `send(&mut writer, …)` call sites became `wire.reply(…)`; everything the
  regex got wrong failed to compile. What needed care was the two presence
  loops, because their LED behaviour is a rule of its own.
- **Naming is part of the measurement.** The remaining function was renamed
  `ctap2_task`, because it dispatches CTAP2 and no longer implements CTAP-HID —
  and a name that says otherwise makes `duplication.sh` count a transport that
  is not there.

What was *not* re-verified is written into exp194's README rather than left to
be discovered: exp189's `hmac-secret` transcripts were recorded before the port
and need a finger on BOOTSEL to redo.

## What is still not verified

- **Only HID has been composed on `cdc-console`.**
  [exp193](../experiments/exp193-how-many-doors-fit/) verified the two-phase API
  on hardware and found the wall it was looking for in the wrong place — the
  first limit is `embassy-usb`'s `MAX_INTERFACE_COUNT`, default 4, of which the
  console spends 2. MSC, NCM and vendor interfaces have not been put through it.
- **The `lifeline::led` swap has not been seen.** `drop.sh` rules on the log,
  and an LED is not in the log. The conditions and the millisecond constants are
  identical on both sides, so this is a confirmation owed rather than a doubt.
- **One copy of thirteen has been removed.** exp189 was ported onto
  `crates/ctap-hid` and the count went 22,629 → 21,526, the first reduction. The
  other twelve `ctaphid_task`s are untouched, and at this rate the backlog
  outlives the ratchet by a wide margin: the ratchet's job is that it stops
  growing, not that it shrinks.
- **The Python backlog has no plan.** 5,950 lines in 30 duplicated functions are
  now visible and nothing has been extracted from them; `tools/ctaphid/` is the
  only host-side thing that has moved. The ratchet stops it growing.
- **The detector counts names, not similarity.** Two functions sharing a name and
  nothing else are counted as copies, and two identical bodies under different
  names are not counted at all. exp194 met the first: a 17-line dispatch loop
  failed the check for sharing a name with a 959-line transport, and the honest
  fix was to rename the thing that had stopped being a transport.
