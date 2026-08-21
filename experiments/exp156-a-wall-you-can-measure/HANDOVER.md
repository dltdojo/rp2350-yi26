# exp156 handover — what eight rounds established

**Status: verified on hardware, 2026-08-20.** Every open question this document
was written to hand over has been answered, and the answers are below with the
rounds that produced them. The eighth round also found that the seventh round's
*result* was right for the wrong reason, which is the part worth reading if you
read nothing else.

## Read this first, and it is not a formality

Every round of this experiment that went badly went badly the same way: a
hypothesis was formed, code was changed, a `.uf2` was handed over, and somebody
walked to a board. Every round that went well started by **reading** — the HAL
source, the PAC, this repository's own earlier experiments — and cost nothing.

[`docs/debugging-without-a-board.md`](../../docs/debugging-without-a-board.md)
is the write-up of that, and its first rule still applies to whatever comes
next:

> **Search prior work before forming a hypothesis. Do not change code first.**

The eighth round obeyed it even with a board attached, and it paid immediately:
the write-key question was settled by finding `ACCESSCTRL_WRITE_PASSWORD` in
OpenOCD's RP2350 flash driver before a single byte was flashed.

## What is known, and how it was established

Rounds 1 to 7 were reported by somebody counting flashes on an LED, on
2026-08-18 and 2026-08-20. Round 8 had a board on the same machine as the work.

| # | Symptom | What it established |
| --- | --- | --- |
| 1 | dark, no USB | `spawn_core1` blocks on `fifo_read()`; it ran three lines before `Driver::new`, so the board could not say so |
| 2 | 3 blinks, then dark | a peripheral still held in RESET faults when read — and the read was on core 0, which owns USB |
| 3 | 4 blinks, then dark | step 5 was three operations inside one millisecond; the count could not name which |
| 4 | ·· ·· ·· pattern | core 0 faulted. The fault handler now drives the LED itself, so *dark* and *died* stopped being the same signal |
| 5 | 5 flashes | it is the `ACCESSCTRL` write |
| 6 | 7 flashes | reads of `ACCESSCTRL` work; an identity write faults |
| 7 | kept blinking, page would not connect | the firmware was fine; `wall.html` had never been run against a board and none of its patterns matched |
| 8 | **the whole log** | **the key is `0xACCE`, the wall was already there, and two reads were never enough** |

### The findings

> **`ACCESSCTRL` writes need `0xACCE` in bits 31:16.** Without it, a write —
> including writing back the value just read, from a Secure Privileged core —
> raises a bus error. With it, the same write is accepted and reads back.

That also explains rounds 5 and 6 exactly. The block's own documentation for
`LOCK` says writes it will not accept *raise a bus error* rather than being
dropped, which is why a missing key looked like a broken register.

> **`ACCESSCTRL.I2C1` is `0x000000fc` at power-on** — `nsu=0 nsp=0 su=1 sp=1
> core0=1 core1=1 dma=1 dbg=1` — and `LOCK` is `0x00000004`, bit 2, DMA, set by
> the bootrom before this firmware runs.

`0xfc` is the register's documented default of *"Secure access from any master"*
exactly, which settles the question the experiment had been working around:
**`rp-pac`'s field names and bit positions are correct and its doc comments are
misattached**, not the other way round.

> **A core demoted by `FORCE_CORE_NS` while it is already running keeps
> running**, and reads what it is still permitted to read.

That is old question 4, answered directly rather than inferred.

> **Clearing NSU and NSP makes that same read fault**, with nothing else in the
> system changed between the two.

### And the finding that was wrong

Round 8's first build reported **VERDICT: the wall is there**, and the verdict
was worthless as written. `0x000000fc` already has NSU and NSP clear, so
`before & !0b11` wrote the value that was already in the register. The wall was
the bootrom's. The firmware had denied nothing and taken credit for the refusal.

The firmware's own log said so — `it did not change. The write was accepted and
ignored, which is not a wall` — and the verdict line above it disagreed. **When
two lines of your own output disagree, the one reporting a measurement wins.**

The fix is a third read, in the middle: open the wall, take a Non-secure read
that *works*, then shut it. See the README.

## What was fixed in round 8, beyond the firmware

- **`usb-log` drops findings, silently.** The outgoing queue is sixteen lines
  deep, drops the newest when full, and nothing drains it until a host asserts
  DTR. A reader who arrived eight seconds late lost the three lines the run
  existed to produce. Fixed here by logging the heartbeat every tenth beat and
  by **putting every finding in the block that repeats every ten seconds**. The
  underlying crate behaviour is unchanged and will bite the next experiment that
  logs a fact once.
- **Log lines are truncated at 96 bytes**, prefix included, and the VERDICT line
  was over it — so the headline finding was cut off mid-sentence in every
  capture. Every line in this firmware is now inside the budget.
- **`wall.html` had never been run against a board.** All of its patterns were
  written from what the log was expected to say and none of them matched. They
  are now checked against a real capture.

## Do not undo these, they were each paid for

`check.sh` guards them all, and each one exists because it was violated:

1. **Nothing that can hang runs before USB is up.** Everything risky is in
   `verdict_task`, which cannot start until the stack is enumerating.
2. **The target peripheral is taken out of reset before it is read.**
3. **The target address comes from the PAC**, never a literal — the first draft
   denied I2C1 and read I2C0.
4. **Every `ACCESSCTRL` write goes through the keyed helper**, because
   `modify()` is a read-modify-write and drops the key.
5. **`ACCESSCTRL.LOCK` is never written.** It survives until reset with no
   software undo. Reading it is fine and the guard was narrowed to allow that.
6. **The fault handler blinks the rung number**, and checks `CPUID` so only
   core 0's death is announced — core 1 faulting is the thing being attempted.
7. **Both controls are asserted separately, and they must agree.** `check.sh`
   fails if read 1 or read 2 is missing, and fails if they returned different
   values. A check that can only see its controls when the experiment passes is
   the defect [exp140](../exp140-a-checksum-that-passes/) is named after, and
   the firmware prints all three reads on every branch so that this one can.

## What is left

- **What kind of fault it is.** The handler catches HardFault and never reads
  `CFSR`, so *BusFault escalated* versus anything else is still unmeasured.
- **Reads only.** Nothing here tries a Non-secure write, a DMA transfer, or the
  debugger against the same wall.
- **Nothing is locked.** `LOCK` is deliberately never written, so every
  configuration this experiment makes is one power cycle from ordinary. An
  experiment that wants a wall to survive its own firmware has to face that
  register, and it cannot be undone by software.
- **There is still no key and no cryptography.** I2C1's hardware ID register is
  not a secret. What was shown is that an address can be made unreachable from
  one core — not that something valuable kept behind it would be safe. That is
  the next experiment.
