# exp158-four-keys-and-one-flash — the board walks the matrix

[exp156](../exp156-a-wall-you-can-measure/) spent **three separate bench trips**
on one question. `ACCESSCTRL` reads fine and refuses every write — so what does a
write need?

| round | what a human walked to a board to find out |
| --- | --- |
| 5 | it is the write, not the read |
| 6 | *any* write faults, including writing back the value just read |
| 7 | a key in the top half is the ordinary reason — try `0xACCE` |

Three flashes, three walks, one bit each.

This asks the whole question in **one flash**, in about fifty seconds, and the
board does the walking.

## The claim

> **A firmware that dies on a candidate comes back, steps over it, and tries the
> next one — so one flash answers a matrix of hypotheses instead of one.**

```text
  boot 1   key 0x0000   faults. Marked, stepped over.
  boot 2   key 0x5afe   faults. Marked, stepped over.
  boot 3   key 0xacce   survives, and the register changes.
  boot 4   key 0xdead   faults. Marked.
  boot 5   nothing left to try. Reports all four, for as long as it is powered.
```

[exp157](../exp157-a-note-for-the-next-boot/) made a dead run able to file a
report. This is the half that acts on one.

## Why this payload, and not something harmless

**Because the answer was already measured.** exp156 established on hardware that
`0xACCE` in bits 31:16 is accepted and that a write without it takes a bus fault.
So this run has a right answer to be wrong about: a harness that mislabels a
candidate, quietly retries one, or reports a plausible table it never measured
**gets caught by `check.sh`**.

A synthetic matrix would have demonstrated the mechanism and proved nothing about
whether it replaces a human round, which is the only claim worth making.
[exp140](../exp140-a-checksum-that-passes/) is what this repository calls a check
that cannot fail.

`0xACCE` is deliberately **third**. The run has to come back from two deaths
before it reaches the answer, and then carry on *past a success* to a fourth
candidate — so stepping over a death and stepping over a win are both exercised,
and neither can be the accident that makes it look right.

## What each candidate does

Read `ACCESSCTRL.I2C1`; write it back with **NSU and NSP set** using that
candidate's key; read it again; then put the original value back **using the same
candidate's key**.

Restoring with the candidate's own key rather than with the known-good one is not
a detail. It keeps each candidate self-contained and stops the answer being
smuggled into the test.

**Surviving is not the same as being accepted.** A write that is silently ignored
also survives, and telling those apart is the whole question — so a candidate
counts as accepted only if the register actually changed.

Three outcomes, and the firmware can only report two of them itself:

| outcome | who records it |
| --- | --- |
| **DIED** | the crate, on the next boot — nobody was alive to report it |
| **ACCEPTED** | the firmware, having seen the register change |
| **ignored** | the firmware, having seen it not change |

## How it stays safe

Everything exp157 paid for, kept:

1. **`breadcrumb::read()` disarms first, unconditionally** — a boot can never
   inherit an armed watchdog.
2. **Five seconds enumerated with nothing armed** at the top of every boot, and
   it says so in the log.
3. **A hard stop** at eight boots whatever happens; four candidates plus the
   reporting boot is five, so anything more means something is retrying.

Verified afterwards: still `running`, still enumerated, still enters BOOTSEL from
`yi26 bootsel` with nobody near the button.

**`ACCESSCTRL.LOCK` is never written** — it survives until reset with no software
undo, and `check.sh` greps for that rather than trusting this sentence. Every
change here is one power cycle from ordinary, and the candidate that succeeds
puts the register back before it reboots.

## How to see it

```sh
./check.sh                      # exit 0, and it asserts the whole table
yi26 log --json --seconds 25    # the settled table, repeating every ten seconds
```

The run takes about **fifty seconds** and the port disappears four times while it
goes, so `yi26 log` returns fragments until it settles. `check.sh` polls for the
settled state.

The LED is the fallback: **slow** while the matrix is being walked, **fast** once
it is done.

## Expected output

Pasted from a real run on a Pico 2, Ubuntu, 2026-08-20 — flashed with
`yi26 pflash`, then read across the board's own reboots. The port drops between
boots; the fragments are joined and nothing else is edited.

```console
[    3037 ms] exp158 up, boot #1. The matrix so far:
[    3037 ms]   key 0x0000  not tried yet
[    3037 ms]   key 0x5afe  not tried yet
[    3037 ms]   key 0xacce  not tried yet
[    3037 ms]   key 0xdead  not tried yet
[    3037 ms]   0 of 4 keys accepted.
[    3037 ms] reflash window: 5 s, nothing armed. `yi26 bootsel` works now.
[    8037 ms] candidate 1: key 0x0000. I2C1 reads 0x000000fc.

[    3074 ms] exp158 up, boot #2. The matrix so far:
[    3074 ms]   key 0x0000  DIED - the write faulted
[    3074 ms]   key 0x5afe  not tried yet
[    8074 ms] candidate 2: key 0x5afe. I2C1 reads 0x000000fc.

[    3074 ms] exp158 up, boot #3. The matrix so far:
[    3074 ms]   key 0x0000  DIED - the write faulted
[    3074 ms]   key 0x5afe  DIED - the write faulted
[    8074 ms] candidate 3: key 0xacce. I2C1 reads 0x000000fc.
[    8274 ms]   survived, and 0x000000fc -> 0x000000ff. ACCEPTED.

[    3074 ms] exp158 up, boot #4. The matrix so far:
[    3074 ms]   key 0xacce  ACCEPTED - the register changed
[    3074 ms]   key 0xdead  not tried yet
[    3074 ms]   1 of 4 keys accepted.
[    8074 ms] candidate 4: key 0xdead. I2C1 reads 0x000000fc.

[    3074 ms] exp158 done after 5 boots. Nothing armed; still reflashable.
[    3074 ms]   key 0x0000  DIED - the write faulted
[    3074 ms]   key 0x5afe  DIED - the write faulted
[    3074 ms]   key 0xacce  ACCEPTED - the register changed
[    3074 ms]   key 0xdead  DIED - the write faulted
[    3074 ms]   1 of 4 keys accepted.
[    3074 ms] VERDICT: the board walked four candidates in one flash.
```

Note `I2C1 reads 0x000000fc` at the top of candidate 4: candidate 3 changed the
register to `0x000000ff` and put it back before rebooting.

`./check.sh` on the same board:

```console
PASS  toolchain present (cargo, elf2flash)
PASS  firmware compiles (214452 byte ELF)
PASS  converts to UF2 (45568 bytes)
PASS  UF2 family ID is e48bff59 (rp2350-arm-s)
PASS  the firmware never writes ACCESSCTRL.LOCK
PASS  the product string is bounded at build time
PASS  the LED heartbeat starts before the USB stack
PASS  the run has a hard stop that disarms
PASS  board enumerated as 1209:0001
PASS  every candidate was attempted
PASS  at least one candidate killed the board, and it came back
PASS  0xacce was accepted, and the register changed
PASS  exactly one of four keys was accepted
PASS  all three wrong keys were refused
PASS  the run stopped and said so
```

## What this does not do

- **It does not choose its own candidates.** The list is compiled in. A board
  that could *generate* the next hypothesis from the last result would be a
  different and much larger thing, and nothing here needs it.
- **It does not help before USB is up.** The table is reported over USB, so a
  death during enumeration still leaves only the LED — the honest limit inherited
  from [exp157](../exp157-a-note-for-the-next-boot/) and the reason exp156's
  Rule 2 is still the whole instrument down there.
- **Sixteen steps, two bits each.** That is one scratch register, and it is the
  ceiling on how long a matrix can be.
- **It proves nothing about the wall.** exp156 did that. This borrows its answer
  as a target to be measured against.

## The ideas to take away

1. **The loop can contain the board instead of a person.** Three bench trips
   became one flash and fifty seconds, and the difference is not speed — it is
   that nobody had to be there. Every question that costs a human trip is a
   question that does not get asked at night.

2. **Step over the thing that killed you.** A harness that retried the candidate
   that just faulted would never finish, which is why the crate marks a died step
   *before* handing the list back. It is one line, and it is the whole of the
   idea.

3. **Point a new instrument at a question that has already been answered.** The
   temptation is to aim it at the unknown immediately, because that is what it is
   for. But an instrument's first reading should be one you can check, or you
   have two unknowns and no way to separate them.

## Next

The signing road's third experiment: ECDSA P-256 behind exp156's wall — with an
instrument that survives its own failures, and a board that can try four things
while nobody is watching.
