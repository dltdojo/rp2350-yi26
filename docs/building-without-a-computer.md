# Building without a computer

Every experiment here assumes a machine with a Rust toolchain on it. That
assumption costs money, an operating system somebody is allowed to install
things on, and an afternoon — and for a reader who owns a phone and a board and
nothing else, it is the whole barrier.

It does not have to be. **Compiling and flashing are separable**, which
[`platforms.md`](./platforms.md) already lays out: something else builds the
`.uf2`, and the computer you already own drags it onto the boot drive. This
document is about the case where *the computer you already own is a phone*, and
the thing that builds the `.uf2` is an AI session in the cloud that you talk to
in sentences.

The result is a loop with **no computer in it at all**, and a real limit worth
knowing before you plan around it.

## What the loop actually is

```
你 (手機)  ──「把閃爍改成快閃五秒、慢閃五秒」──▶  雲端 AI session
                                                    │ 編輯 src/main.rs
                                                    │ cargo build --release
                                                    │ elf2flash convert -b rp2350
             ◀──────────── exp103.uf2 ──────────────┘
   │
   ├─ 手機下載 .uf2
   ├─ 板子進 BOOTSEL（exp103–104 要用手按；exp105 之後 bootsel.html 代勞）
   ├─ 手機開 tools/pages/pflash.html，把 .uf2 寫進去
   └─ 看 LED，或用 log.html 讀日誌
```

Steps 3 to 5 are the phone-flashing track this repository already built —
[`pflash.html`](../tools/pages/pflash.html) writes a `.uf2` into a board that is
already in BOOTSEL, over the bootrom's own PICOBOOT interface, with no toolchain
and no server. See [`tools/pages/`](../tools/pages/). What is new here is only
step 1 and step 2: **the machine that compiles does not have to be yours, and
you do not have to know how to drive it.**

## This was measured, not imagined

Everything below was done in one cloud session on 2026-08-18, against this
repository, with no board attached and nothing installed by hand beforehand.

| | |
| --- | --- |
| `cargo` / `rustc` | already there — 1.97.1 |
| `thumbv8m.main-none-eabihf` | already installed |
| `cargo build --release` on exp103 | **27 s** from cold, 138,048-byte ELF |
| `elf2flash convert -b rp2350` | 9,728-byte `.uf2`, family ID `e48bff59` |
| `./check.sh` | four PASS, exit 0 |

Then the same session was asked, in one sentence, for five seconds of fast blink
followed by five of slow. It edited the loop in `src/main.rs`, rebuilt, and
produced a **10,240-byte** `.uf2` — one 512-byte block larger, which is the
added loop — with the same family ID. Both files were handed back as downloads.

**One thing was missing and had to be installed**: `elf2flash` links against
libudev, so `cargo install elf2flash` fails on a clean container until
`libudev-dev` is there, and the package index has to be refreshed first or the
download 404s. That is now a row in
[exp102's troubleshooting table](../experiments/exp102-rust-toolchain/README.md#troubleshooting),
which is where somebody hitting it will look.

## The limit, in this repository's own vocabulary

Every experiment carries a **Needs** level, 0 to 3 — see
[Which of these can I do right now](../experiments/README.md#which-of-these-can-i-do-right-now).
It says how much of a *person* verifying the claim costs.

**A cloud AI session is a Needs 0 machine.** It can do everything an experiment
needs up to and including the `.uf2`, and nothing whatsoever after it. It cannot
press BOOTSEL, it cannot see the LED, and it cannot read the log, because it is
not in the room and there is no board on the other end of it.

That is not a shortcoming of any particular product. It is the same line the
Needs column has been drawing all along, and the reason exp103 — the simplest
firmware here — is a **level 3**: no software in this repository can watch a
light.

So the honest description of this path is:

> **The agent does the part that needs a toolchain. You do the part that needs
> a room.**

### What that costs

An AI agent is at its best when it can run the thing it just changed, read what
happened, and fix it — a loop it can close in seconds, many times, unattended.
Split the loop across a person and it stops being that. Every iteration now
waits on somebody to download a file, hold a button, and look at a light, and
the agent is working blind in between.

Expect it to be **slow, and to need you to describe what you saw**. "The LED
did not come on at all" and "it blinks but far too fast" send the next attempt
somewhere completely different, and the agent has no way to tell them apart on
its own. Say which one it was.

That trade is worth making anyway when the alternative is not doing the
experiment at all.

## Which experiments can I actually do

The first question anybody asks after reading the above is *"so which ones can
I do — all of them?"*, usually alongside the reasonable-sounding claim that **if
the phone can install the `.uf2`, the phone can confirm the result**.

The first half is nearly true. The second half is the one to take apart, and
it is worth taking apart carefully, because getting it wrong sends somebody to
flash a board and then stare at it wondering what they were supposed to see.

### Flashing, observing and verifying are three different things

| | What it means | On a phone |
| --- | --- | --- |
| **Flashing** | the `.uf2` gets into the board | yes, with `pflash.html` — see the traps below |
| **Observing** | you can tell what the firmware did | yes, for nearly everything |
| **Verifying** | `check.sh` returns a verdict | **no, for most of them** |

That last row is the one the claim misses. Most `check.sh` scripts here drive
the board through [`yi26`](../tools/README.md), which is a program that runs on
a Linux host. A phone can flash a board and watch it work and still not be able
to run the thing that says PASS. Count them for yourself:

```sh
ls experiments/exp*/check.sh | wc -l                 # all of them
grep -l 'yi26 ' experiments/exp*/check.sh | wc -l    # the ones a phone cannot run
```

**You will see the experiment. You will not get its verdict.** For a class that
is often fine — the verdict was somebody else's evidence, and the point is the
thing the board does — but it should be said rather than discovered.

### The Needs column does not answer this question

Every experiment carries a `Needs` level, and it is tempting to read it as the
answer. It is not.
[Needs](../experiments/README.md#which-of-these-can-i-do-right-now) measures
**how much of a person** an experiment costs. This question is about **how much
of a computer**. The two axes are not parallel, and the clearest proof is
level 1, *"a board attached, and nothing but software after that"* — where the
software in question is `yi26`, which is the very thing a phone does not have.

### What does answer it: the declarations in each check.sh

Every experiment declares what its USB link is and who claims it — the same
tokens [`usb_check`](../experiments/lib.sh) validates against the table in the
[experiments index](../experiments/README.md#which-layer-of-usb-is-this). Those
are what to read:

```sh
grep -H '^USB_IFACE=\|^USB_RUNS_ON=' experiments/exp*/check.sh
```

- **`USB_IFACE` contains `cdc`** — the firmware has a serial log, and a phone
  reads it with [`log.html`](../tools/pages/log.html) or
  [`console.html`](../tools/pages/console.html). WebUSB claims a CDC-ACM
  interface directly, which is not obvious and is exactly what
  [exp116](../experiments/exp116-webusb-cdc-log/) exists to prove. This is most
  of the firmware in this repository.
- **`USB_IFACE` is `none`** — no USB at all. Three say this, and telling them
  apart matters: two of them need no board in the first place, so there is
  nothing to flash and nothing to watch. The third,
  [exp103](../experiments/exp103-embassy-blink/), has firmware and no way at all
  to talk about it, so the only evidence is the LED and your eyes. It is the
  simplest firmware here and the one with the least standing between your change
  and something you can see.
- **`USB_RUNS_ON` is not `own`** — the experiment has no firmware of its own and
  runs against somebody else's. `any` will work with whatever is on the board;
  `exp118` means exp118 and nothing else.

### Start here

**To run something end to end, verdict included, without flashing anything:**
[exp115](../experiments/exp115-webusb-enumerate/),
[exp116](../experiments/exp116-webusb-cdc-log/) and
[exp117](../experiments/exp117-webusb-reboot/). They have no firmware of their
own — they need only that the board already has *some* — and they were built
for a phone from the start. There is no `yi26` step to be missing, because the
browser is doing the whole job.

**To watch your own edit become a physical thing:**
[exp103](../experiments/exp103-embassy-blink/). Change the numbers in
`src/main.rs`, ask for a `.uf2`, flash it, look at the LED. Nothing stands
between the change and the evidence — which is also why it is filed as a
Needs 3.

### Three traps worth knowing before the first attempt

1. **From [exp139](../experiments/exp139-a-table-of-one/) on, dragging the
   `.uf2` onto the drive does nothing.** Those firmwares carry a partition
   table, and [exp144](../experiments/exp144-one-file-either-half/) measured
   that the ROM's own drive refuses a dropped file while a table exists. Use
   [`pflash.html`](../tools/pages/pflash.html), which speaks PICOBOOT and does
   not consult the table. This fails *quietly*, which is the worst way for a
   first attempt to fail.
2. **Getting into BOOTSEL has two routes and they are not interchangeable.** A
   board running exp103 or exp104 has no USB to ask, so it needs a hand on the
   button. From [exp105](../experiments/exp105-usb-reboot/) on the firmware
   reboots itself and [`bootsel.html`](../tools/pages/bootsel.html) does it from
   the phone.
3. **The browser experiments are picky about what is already on the board.**
   [exp120](../experiments/exp120-webusb-two-way/) works against exp118 and
   nothing else; [exp135](../experiments/exp135-a-packet-with-no-bytes/) against
   exp128. Flash the wrong one and the page fails for no visible reason.
   `USB_RUNS_ON` is where each of them says so.

### One thing that is not a trap

**No experiment here needs hardware beyond the board and its cable.** No
breakout, no jumper wires, no external supply — [exp127](../experiments/exp127-host-owns-the-led/)
even records deciding against jumper wires on purpose. A phone, a board and a
cable is the whole list.

## What to ask for

The agent has the whole repository, so ask for the outcome and let it find the
files. Three shapes that work:

**Read it to me.** Paste a link to an experiment and ask what it proves and
what it will cost you to run — the `Needs` level answers whether you can do it
alone tonight or need somebody at a bench.

**Change it and hand me the file.**

> exp103 的 LED 在 GPIO 16，不是 25。改好後給我 UF2。

> Make exp103 blink twice quickly then pause for a second, and give me the
> `.uf2`. Don't commit anything.

Say **"don't commit"** when it is a throwaway test — otherwise you may get a
branch you did not want. The `.uf2` is a build artifact and is not in version
control either way; asking for the diff as well means you can re-apply the
change later without re-deriving it.

**Review it.** Ask for a reading of an experiment's `src/main.rs` against its
README, or for the thing you are about to flash to be checked before you flash
it. This is the cheapest use of the whole arrangement, because nothing has to
travel to a board for it to be useful.

## Two things to check before you trust a `.uf2` somebody's agent built

Both are one line, and both are what `check.sh` already does:

1. **The family ID is `e48bff59`.** A UF2 block carries one at byte offset 28
   whenever bit `0x2000` of its flags is set, and `e48bff59` is RP2350 Arm
   (secure). A file built for the wrong chip will be copied onto the drive
   perfectly and do nothing. Read more than the first block: a legitimate image
   can mix families — exp177 met a released one whose first block is padding in
   the `absolute` family — and the question is whether **any** block is this
   chip's, not what the first one says.
2. **The size is plausible.** exp103 is under 10 KB. A `.uf2` that is suddenly
   ten times bigger is a different program from the one you asked for.

Ask for both to be stated with the file. An agent that produces a `.uf2` and
does not say what it verified about it has handed you a file, not a result.

## Which product, and what this document will not tell you

Two arrangements were in view when this was written: **Claude Code on the web**,
which runs a session in a cloud VM configured per repository, and the plain
chat sandbox, which also runs code. Both can reach the end of step 2. They
differ in how much survives between sessions, how the repository gets in and
out, and what the account is billed.

**Those details are not written down here on purpose.** They are one vendor's
policy, they change on their own schedule, and a copy of them in this
repository would be wrong without anything here changing — which is exactly the
failure this repository spends effort avoiding elsewhere. Read the vendor's own
documentation for what an environment includes, what persists, and what it
costs.

What *is* written down here is the part that belongs to this repository and does
not move: the loop, the limit, and the two checks.
