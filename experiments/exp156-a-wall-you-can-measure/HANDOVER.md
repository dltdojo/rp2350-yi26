# exp156 handover — read this before changing anything

**Status: unverified, and blocked on a board.** Seven flash cycles have happened,
each one costing somebody a walk to a bench, and the sequence of findings below
is worth more than the code. **Do not start by rewriting the firmware.**

## Read this first, and it is not a formality

Every round of this experiment that went badly went badly the same way: a
hypothesis was formed, code was changed, a `.uf2` was handed over, and somebody
walked to a board. Every round that went well started by **reading** — the HAL
source, the PAC, this repository's own earlier experiments — and cost nothing.

[`docs/debugging-without-a-board.md`](../../docs/debugging-without-a-board.md)
is the write-up of that, and its first rule is the one to apply here:

> **Search prior work before forming a hypothesis. Do not change code first.**

## What is known, and how it was established

Each line is a measurement on a real Pico 2, reported by somebody counting
flashes on an LED, on 2026-08-18 and 2026-08-20.

| # | Symptom | What it established |
| --- | --- | --- |
| 1 | dark, no USB | `spawn_core1` blocks on `fifo_read()`; it ran three lines before `Driver::new`, so the board could not say so |
| 2 | 3 blinks, then dark | a peripheral still held in RESET faults when read — and the read was on core 0, which owns USB |
| 3 | 4 blinks, then dark | step 5 was three operations inside one millisecond; the count could not name which |
| 4 | ·· ·· ·· pattern | core 0 faulted. The fault handler now drives the LED itself, so *dark* and *died* stopped being the same signal |
| 5 | 5 flashes | it is the `ACCESSCTRL` write |
| 6 | **7 flashes** | **reads of `ACCESSCTRL` work; an identity write faults.** Writes are refused whatever the value |
| 7 | keeps blinking, page will not connect | **unresolved — see below** |

### The finding that matters

> **`ACCESSCTRL` is readable and refuses every write, including writing back the
> value just read, from a Secure Privileged core.**

The register documents itself as *"writable only from a Secure, Privileged
processor or debugger"*, which is exactly what core 0 is. `rp-pac` models no
write key: `Access` is a `u32` with fields only in bits 0..7, so `modify()`
reads a register whose top half is zero and writes zero back there.

The current build tests one hypothesis: a **write key `0xACCE` in bits 31:16**.
It is a hypothesis and is labelled as one in the source. **Check the RP2350
datasheet before trusting it** — nothing here has read one.

## The state nobody has explained yet

Round 7, with the keyed write: **the LED keeps blinking and `wall.html` cannot
connect at all.**

That is a state none of the earlier rounds produced, and **it has not been
diagnosed**. What is not known:

- **Slow or fast?** Slow (1 Hz) means no verdict and core 1 is stuck. Fast
  (5 Hz) means `FAULTED` is set and there *is* a verdict to read. Nobody
  recorded which, and it changes the diagnosis completely.
- **Did USB enumerate?** A page that cannot connect and a board that never
  enumerated look identical from the phone. `inspect.html` or `yi26 state`
  separates them; the chooser now includes `2e8a:000f` so BOOTSEL is
  distinguishable, but a board enumerating as `1209:0001` and refusing to be
  claimed is not.
- **Stale chooser entries?** `docs/debugging-on-a-phone.md` records one board
  appearing several times with only one live entry, and nothing in the names
  saying which.

**Establish which of those it is before changing a line.** Three of them need no
rebuild at all.

## What the next agent has that this session did not

**A board on the same machine.** That changes the economics completely: the
whole reason this experiment grew an elaborate LED protocol is that each
observation cost a human walk. With a board attached:

- `yi26 log --json --seconds 20` gives the whole log, including the two values
  round 5 and 6 produced and nobody has yet read: **`LOCK` and the power-on
  value of `ACCESSCTRL.I2C1`**.
- Those two values settle a question this experiment has been working around
  since it was written: `rp-pac`'s doc comments for `Access` are **shifted by
  one field** — `su` carries NSP's sentence, `core1` carries CORE0's. Either the
  names are right and the docs misattached, or the docs are right and the fields
  misnamed. **A power-on value distinguishes them**, and every bit written so
  far was written without that being settled.
- `./check.sh` runs the board-dependent half.
- The twenty-second wait before the first write exists only so a human could
  open a page in time. **Delete it** once a log can be read directly.

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

## Open questions, in the order worth asking

1. **Is `0xACCE` the key?** Datasheet first. If not, what is refusing the write?
2. **What are `LOCK` and `I2C1`'s power-on values?** Already produced by the
   firmware; nobody has read them.
3. **Does the PAC's field naming match the silicon?** Answered by (2).
4. **Can a core already executing be demoted by `FORCE_CORE_NS`?** Once core 1
   is Non-secure every instruction fetch is a Non-secure access, including the
   fetch of its own fault handler. A core that cannot execute anything is a
   different outcome from a core refused one address, and only the flash count
   separates them.
5. **Is ACCESSCTRL even the right wall for the signing road?** It gates bus
   requests; the SAU partitions the address space. This experiment chose
   ACCESSCTRL because `embassy-rp` has no SAU support and because it puts the
   fault on a core that is not holding USB. If ACCESSCTRL turns out to be
   unwritable for a reason that does not go away, that choice is worth
   revisiting rather than forcing.

## What this experiment still has to prove

Unchanged since it was written, and none of the seven rounds has reached it:

> **This address is readable from one place and not from another, and both
> halves were watched.**

A read that faults could be a broken core. A read that works says nothing about
anybody else. **Only both, on the same address, in the same run.**
