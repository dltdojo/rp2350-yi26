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

None of these is a bug in an experiment's subject. Each is a bug in the part of
the firmware that was never what the experiment was asking about, carried
forward by copying, and paid for again.

---

## The size of it, counted

`./duplication.sh` groups every top-level function in `experiments/*/src/*.rs`
by name and reports how many experiments define it and how many textually
distinct versions exist between them.

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
| 1 | CTAP-HID transport → `crates/ctap-hid` | 14 copies, 13 versions, 959 lines at the head | Largest single win in the tree. What remains in each experiment is its `get_info`/`makeCredential` policy — which is the subject. `crates/ctap` is 62 lines: the extraction barely started |
| 2 | MSC/SCSI + FAT12 glue → `crates/msc-disk` | 12 copies, 7 versions, 262 lines | `crates/fat12` exists and is tested; what is missing is the layer between it and USB |
| 3 | CDC command console → `cdc-console`'s second phase | 17 copies, 14 versions | The crate exists; it needs `open` to hand back a reader |
| 4 | `blink_task` / `heartbeat` | 21 + 12 copies, 5 versions each | Already solved by `lifeline::led`; only adoption is missing |

**Do not extract ahead of a caller.** `crates/cdc-console` deliberately has no
method for handing the `Builder` back to a composite firmware, because the
seventeen experiments that would want one are not being rewritten and no new one
has asked yet. An API shaped for a caller that does not exist is an API nobody
has been able to catch being wrong, which is
[exp140](../experiments/exp140-a-checksum-that-passes/)'s subject. The first
real caller decides the shape, and verifies it on hardware in the same round.

---

## Measured, 2026-08-30

The first application of this document, on exp190:

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

## What is still not verified

- **No composite firmware runs on `cdc-console`.** The seventeen experiments
  that add HID, MSC or a vendor interface to the same `Builder` have no path
  through it, by design, and the two-phase API is therefore an untested idea.
- **The `lifeline::led` swap has not been seen.** `drop.sh` rules on the log,
  and an LED is not in the log. The conditions and the millisecond constants are
  identical on both sides, so this is a confirmation owed rather than a doubt.
- **Nothing has been extracted at scale yet.** cdc-console is 199 lines against
  a 22,629-line problem. The ratchet stops it growing; it does not shrink it.
