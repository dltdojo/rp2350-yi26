# exp164 — the wall nobody read

Six experiments built a security story on **ACCESSCTRL**, which is Raspberry
Pi's own bus filter. None of them ever looked at the **SAU**, which is what the
Armv8-M architecture means by TrustZone. This one reads it, and the reading
corrects a word those six have been using.

The first experiment on the [attribution road](../README.md#the-attribution-road),
and the seventh built for the [signing road](../README.md#the-signing-road) before
reading the SAU turned out to be a different subject.
Nothing here is cryptography, and nothing here writes anything.

## What it is for

[exp156](../exp156-a-wall-you-can-measure/) chose ACCESSCTRL over the SAU and
said why, and the reasons were good: `embassy-rp` has no SAU support, `rp-pac`
models ACCESSCTRL in full, and `ACCESSCTRL.FORCE_CORE_NS` demotes a whole core
with no hand-written `SG` veneer. It promised the veneer to a later experiment.

This is not that experiment. This is the one that should have come first.

exp156, [exp159](../exp159-a-key-that-was-never-in-flash/),
[exp160](../exp160-a-secret-too-big-to-hide/),
[exp162](../exp162-how-wide-can-a-wall-be/) and
[exp163](../exp163-how-long-is-a-secret-in-the-open/) all depend on core 1
running **Non-secure** — fetching instructions from flash, running on a stack in
SRAM, in exp163's case reading half a megabyte of it in a loop. Security
attribution on Armv8-M is not ACCESSCTRL's business: it comes from the SAU and
the IDAU, before a request ever reaches the bus. So **something already
attributes this chip's memory**, or none of those five could have run — and
nobody had read what.

## What was measured before any of this was designed

| fact | how | what it changed |
|---|---|---|
| `cortex-m` **already ships the SAU register block**, `src/peripheral/sau.rs`, `#[cfg(armv8m)]`, and its `build.rs` sets that cfg for `thumbv8m.main-none-eabihf` | read the crate | ← the SAU is reachable **on stable**, from a dependency already in every experiment's lockfile. exp156's "no SAU support" is true of the HAL and not of the architecture crate under it |
| `cortex-m` also ships `src/cmse.rs`: `TT`, `TTT`, `TTA`, `TTAT` | read the crate | ← **the instrument.** `TestTarget::check` asks the hardware about an address *without accessing it*, and reports `secure()`, `ns_readable()`, `idau_region()` and `sau_region()` separately, so an answer says which unit decided |
| nothing in `embassy-rp` mentions SAU, TrustZone or Non-secure | grepped the HAL | candidate 2 checks it on silicon instead of trusting the grep |
| `rp-pac` defines `SIO` at `0xd000_0000` **and `SIO_NS` at `0xd002_0000`** | read the PAC | the RP2350 publishes Non-secure aliases, so the map tests aliases as well as originals |
| only `extern "cmse-nonsecure-entry"` needs nightly | tried it | *configuring* the SAU does not. The nightly wall is the veneer, not the unit |

## Read-only, and why that is not a survey

Nothing here writes the SAU. The only write in the firmware is `SAU_RNR`, which
selects which region the next read returns and changes no attribution —
`check.sh` counts the writes and where they go on every run. Enabling regions
would repartition the memory this firmware is running out of, and the honest
order is to find out what the bootrom left before planning anything on top of
it: [exp138](../exp138-what-the-rom-already-knows/)'s order, and
[exp154](../exp154-somewhere-to-put-a-key/)'s.

A dump with no possible failure would still be worth nothing, so four of the six
candidates can come out the other way.

## The six candidates

One per boot, one flash, driven by [`breadcrumb`](../../crates/breadcrumb/).

| # | what it does | graded on |
|---|---|---|
| 1 | reads `SAU_TYPE` and all its regions | the address matches `cortex-m`'s `SAU::PTR`, and `SREGION > 0` |
| 2 | compares the SAU **before and after `embassy_rp::init()`** | the four registers are identical |
| 3 | asks `TT` about eighteen addresses | *the instrument ran* — never what it found |
| 4 | shuts bank 8 in ACCESSCTRL and asks `TT` again | the `TT` answer is unmoved |
| 5 | a `FORCE_CORE_NS` core reads the Secure SAU, then a shut bank | **the refusal** — the SAU values are measured, not graded |
| 6 | the same, with `FORCE_CORE_NS` set *before* core 1 starts | the launch does not complete |

Candidate 3 is ungraded on purpose. The map is the thing the experiment was
written to find out, and naming an expected attribution in the matrix would be
writing down an answer the run cannot contradict — exp162's lesson, and this
firmware needed it: **the first version of candidate 5 demanded that the demoted
core be refused the SAU, got the opposite, and reported the finding as a failure
of the board.**

## The result

One run on a Pico 2, 2026-08-21. All six candidates came back as expected.

### The SAU is on, and it describes almost nothing

```
SAU: CTRL=0x00000001 TYPE=0x00000008 SFSR=0x00000000 SFAR=0xe000ede8
  r0 RBAR=0x00000000 RLAR=0x00000000 -> 0x000000..0x00001f en=0 nsc=0
  ...
  r6 RBAR=0x00000000 RLAR=0x00000000 -> 0x000000..0x00001f en=0 nsc=0
  r7 RBAR=0x000046a0 RLAR=0x00007fe1 -> 0x0046a0..0x007fff en=1 nsc=0
```

`ENABLE=1`, `ALLNS=0`, **eight regions, one of them enabled** — region 7,
covering `0x46a0..0x7fff`, which is the upper part of the bootrom, marked
Non-secure and not Non-secure-Callable. Everything else is a zero.

`SFSR` is zero: no SecureFault has been recorded. `SFAR` reads as its own
address, which is what an architecturally UNKNOWN register is allowed to be, and
nothing here rests on it.

`embassy_rp::init()` moves none of it. The grep said the HAL never names the
SAU; candidate 2 says it never moves it either.

### The map, and it is one colour

Eighteen addresses, asked with `TT`, which does not access them:

```
  0x00000000 bootrom, base          S=yes nsr=no  nsrw=no  idau=-1 sau=-1
  0x00005000 bootrom, inside r7     S=yes nsr=no  nsrw=no  idau=-1 sau=-1
  0x10000000 XIP flash              S=yes nsr=no  nsrw=no  idau=-1 sau=-1
  0x20000000 SRAM bank 0            S=yes nsr=no  nsrw=no  idau=-1 sau=-1
  0x20080000 SRAM bank 8            S=yes nsr=no  nsrw=no  idau=-1 sau=-1
  0xd0020000 SIO_NS                 S=yes nsr=no  nsrw=no  idau=-1 sau=-1
  0xe000e000 SCS                    S=yes nsr=no  nsrw=no  idau=-1 sau=-1
```

**Every address on this chip is Secure and none of it is Non-secure-readable** —
including `SIO_NS`, which exists in the PAC precisely as a Non-secure alias.

And that is the sentence that makes the rest of this experiment necessary,
because exp159 through exp163 all ran a core that read this memory while
ACCESSCTRL was calling it Non-secure.

### The word six experiments have been using

Candidate 5 demotes core 1 with `FORCE_CORE_NS`, has it read the Secure SAU,
and *then* has it read a bank shut in ACCESSCTRL:

```
  core 1: up=true read_done=true faulted=true finished=false
  SAU_TYPE  core 0 0x00000008   core 1 0x00000008
  SAU_CTRL  core 0 0x00000001   core 1 0x00000001
  TT of 0x20000000  core 0 0x004c0000   core 1 0x004c0000
```

`faulted=true finished=false` is the control: the demotion is real, and
ACCESSCTRL refused the bank exactly as exp159 and exp160 describe.

Everything above that line is the finding. Core 1 read the **Secure** System
Control Space and got core 0's values, and its `TT` response is core 0's
response bit for bit — `0x004c0000`, which is `R=1`, `RW=1`, **`S=1`**, with
`SRVALID`, `IRVALID` and `MRVALID` all clear. `TT`'s `S` bit is only meaningful
when the instruction executes in Secure state.

> **`ACCESSCTRL.FORCE_CORE_NS` marks the bus, not the core.** What this
> repository has been calling a "Non-secure core" is Non-secure **to
> ACCESSCTRL** and Secure **to the architecture**.

Every measurement in exp156, exp159, exp160, exp162 and exp163 stands: the wall
refused, the key leaked, the banks interleave, the wipe worked. What changes is
the word. Those experiments demonstrate a **bus-level access filter**, not
Armv8-M state separation, and the two are not the same thing to anybody reading
them for a lesson about TrustZone.

### There is no other ordering

Candidate 6 is the only way that conclusion could have been wrong: if
`FORCE_CORE_NS` were sampled when core 1 comes out of reset, then setting it
*before* the launch — which no experiment here has ever done — might put the
core in Non-secure state for real.

```
  bank 8 SHUT. FORCE_CORE_NS set BEFORE core 1 starts.
  calling spawn_core1 now. If this is the last line, it did not return.
```

It was the last line. `spawn_core1` hands core 1 its entry point over the SIO
FIFO and calls `fifo_read()` after every write, which blocks; sixteen bad
answers and it panics, and `panic-halt` stops core 0, so the watchdog ended the
boot. **With this HAL there is no ordering that starts core 1 Non-secure**, and
the finding above has no hole to escape through.

That line exists because a firmware that proves its point by going silent has
proved nothing a reader can tell from a crash —
[exp134](../exp134-the-log-nobody-reads/) is the record of how many ways silence
reads, and one printed sentence is the cheapest way to make one of them speak.

## One question this does not close

`0x00005000` sits inside region 7, which is enabled and not NSC, and `TT`
reports it Secure and attributes it to **no SAU region at all**.

That is not a decoding mistake. The raw registers are printed next to the
decode — `RBAR=0x000046a0 RLAR=0x00007fe1` — and `verify.py` decodes them again
independently and gets the same answer. `cortex-m` reads `SRVALID` at bit 17 of
the `TT` response, which is where the Armv8-M layout puts it.

So either the IDAU overrides the SAU there, or the descriptor means something
other than it looks like. Settling it needs the Armv8-M Architecture Reference
Manual, which this experiment does not have, and guessing would turn an open
question into a check. `verify.py` therefore derives **one way only** — if `TT`
names a region, that region must exist, be enabled, and contain the address —
and prints the other direction as `OPEN:` instead of failing on it.

## Running it

```console
cd experiments/exp164-the-wall-nobody-read
cargo build --release
elf2flash convert -b rp2350 \
  target/thumbv8m.main-none-eabihf/release/exp164-the-wall-nobody-read \
  target/exp164.uf2
yi26 bootsel && yi26 pflash target/exp164.uf2
yi26 log --seconds 120           # seven boots, about a minute and a half
./check.sh                       # 26 checks
```

Nothing here needs a hand on the board once it is flashed. Candidate 6 ends its
own boot on purpose; the run steps over it and finishes disarmed and
reflashable.

To check a log you already have, on any machine, with nothing installed:

```console
python3 verify.py < capture.txt
```

`verify.py` decodes the eight region descriptors from the raw `RBAR`/`RLAR`
values a second time and compares its decode with the board's, checks that the
map printed in candidate 3's boot matches the map printed in the final report,
and derives what the map may say from what the descriptors say. It does not use
the Armv8-M rule for combining SAU and IDAU attribution, and says so in its own
docstring, because it has no copy of the manual either.

## Expected output

Pasted from a real run on a Pico 2, Ubuntu, 2026-08-21. Trimmed for length;
nothing is edited. The full 175-line run is checked in as
[`capture.txt`](./capture.txt).

```console
[    3187 ms] SAU at entry:      CTRL=0x00000001 TYPE=0x00000008 SFSR=0x00000000 SFAR=0xe000ede8
[    3188 ms] SAU after init:    CTRL=0x00000001 TYPE=0x00000008 SFSR=0x00000000 SFAR=0xe000ede8
[    3188 ms] so: 8 regions, enabled=true, allns=false

[    8225 ms] candidate 2 embassy_rp::init() changes nothing in it
[    8225 ms]   four registers, before and after embassy_rp::init(): identical
[    8225 ms] candidate 2 -> as expected

[    8225 ms] candidate 4 shutting a bank moves nothing the SAU can see
[    8225 ms]   bank 8, ACCESSCTRL open:  S=true nsr=false sau=None
[    8225 ms]   bank 8, ACCESSCTRL SHUT:  S=true nsr=false sau=None
[    8225 ms]   the TT answer is unchanged. The two walls are separate mechanisms.
[    8225 ms] candidate 4 -> as expected

[    8225 ms] candidate 5 what a bus-demoted core sees of the Secure SAU
[    8225 ms]   bank 8 SHUT. FORCE_CORE_NS set after core 1 starts.
[    9235 ms]   core 1: up=true read_done=true faulted=true finished=false
[    9235 ms]   SAU_TYPE  core 0 0x00000008   core 1 0x00000008
[    9235 ms]   SAU_CTRL  core 0 0x00000001   core 1 0x00000001
[    9235 ms]   TT of 0x20000000  core 0 0x004c0000   core 1 0x004c0000
[    9235 ms]   core 1 got the Secure answer to every question. It is not
[    9235 ms]   in Non-secure state; only its bus traffic is marked.
[    9235 ms] candidate 5 -> as expected

[    8225 ms] candidate 6 demoted before core 1 ever started
[    8225 ms]   bank 8 SHUT. FORCE_CORE_NS set BEFORE core 1 starts.
[    8225 ms]   calling spawn_core1 now. If this is the last line, it did not return.

[    3350 ms] exp164 done after 7 boots. Nothing armed; still reflashable.
[    3350 ms]   1 the SAU is implemented and Secure code can read it - as expected
[    3375 ms]   2 embassy_rp::init() changes nothing in it - as expected
[    3400 ms]   3 the map, address by address - as expected
[    3425 ms]   4 shutting a bank moves nothing the SAU can see - as expected
[    3450 ms]   5 what a bus-demoted core sees of the Secure SAU - as expected
[    3475 ms]   6 demoted before core 1 ever started - as expected: the launch never returned
[    3500 ms] SAU: CTRL=0x00000001 TYPE=0x00000008 SFSR=0x00000000 SFAR=0xe000ede8
[    3525 ms]   r0 RBAR=0x00000000 RLAR=0x00000000 -> 0x000000..0x00001f en=0 nsc=0
...                                                       (r1 through r6 the same)
[    3701 ms]   r7 RBAR=0x000046a0 RLAR=0x00007fe1 -> 0x0046a0..0x007fff en=1 nsc=0
[    3726 ms] the map, asked again with TT:
[    3751 ms]   0x00000000 bootrom, base          S=yes nsr=no  nsrw=no  idau=-1 sau=-1
[    3801 ms]   0x00005000 bootrom, inside r7     S=yes nsr=no  nsrw=no  idau=-1 sau=-1
[    3877 ms]   0x10000000 XIP flash              S=yes nsr=no  nsrw=no  idau=-1 sau=-1
[    3952 ms]   0x20000000 SRAM bank 0            S=yes nsr=no  nsrw=no  idau=-1 sau=-1
[    4053 ms]   0x20080000 SRAM bank 8            S=yes nsr=no  nsrw=no  idau=-1 sau=-1
[    4178 ms]   0xd0020000 SIO_NS                 S=yes nsr=no  nsrw=no  idau=-1 sau=-1
[    4203 ms]   0xe000e000 SCS                    S=yes nsr=no  nsrw=no  idau=-1 sau=-1
[    4228 ms] VERDICT: SAU enabled=true, allns=false, 1 of 8 regions enabled.
[    4253 ms]   main SRAM: Secure=true ns-readable=false SAU region None IDAU None
[    4278 ms]   demoted after : read=1 fault=1 TYPE=0x00000008
[    4303 ms]             TT core1=0x004c0000 core0=0x004c0000
[    4328 ms]   demoted before: read=0 fault=0 TYPE=0x00000000
[    4353 ms]             TT core1=0x00000000 core0=0x00000000
[    4378 ms]   a core ACCESSCTRL refuses is a core the SAU still answers.
[    4403 ms]   FORCE_CORE_NS marks the bus, not the core: Non-secure to
[    4428 ms]   ACCESSCTRL, Secure to the architecture.
[    4453 ms]   and there is no other ordering: setting it before the launch
[    4478 ms]   leaves spawn_core1 waiting on a FIFO that never answers.
```

`./check.sh` on the same board:

```console
PASS  toolchain present (cargo, elf2flash)
PASS  firmware compiles (152728 byte ELF)
PASS  converts to UF2 (65024 bytes)
PASS  UF2 family ID is e48bff59 (rp2350-arm-s)
PASS  the firmware never writes the SAU except RNR (which selects, not configures)
PASS  all 2 sau_write calls target RNR and nothing else
PASS  the firmware never writes ACCESSCTRL.LOCK
PASS  the firmware writes nothing permanent (no flash, no OTP)
PASS  the base address is checked against cortex-m's SAU::PTR, on the board
PASS  the map is graded on TT having executed, not on what it said
PASS  candidate 5 is graded on the refusal, and the SAU values are measured
PASS  core 1 stores its reading before the access meant to fault it
PASS  the product string is bounded at build time
PASS  the LED heartbeat starts before the USB stack
PASS  the run has a hard stop that disarms
PASS  verify.py replays the recorded capture
PASS  the corrupted-capture test actually corrupts something
PASS  verify.py rejects a map that contradicts itself (got DISAGREE)
PASS  board enumerated as 1209:0001
PASS  every candidate was attempted
PASS  no candidate died unexpectedly
PASS  all six candidates behaved as expected
PASS  candidate 6: demoting before the launch leaves spawn_core1 waiting
PASS  control: the demoted core read the SAU and was then refused by ACCESSCTRL
PASS  the two cores' TT responses are both in the report (TT core1=0x004c0000 core0=0x004c0000)
PASS  the map follows the region descriptors, derived off the board
```

## What it cost to find out

Seven flashes. Four of them went to the instrument, and three of those were the
same mistake in different clothes: **a sentence that was printed rather than
derived.**

- The first version of candidate 5 asserted that a demoted core would be refused
  the SAU. It was not, and the run reported the finding as `NOT as expected`.
  Rewritten so that the refusal is the grade and the SAU values are a
  measurement.
- The verdict block said "so FORCE_CORE_NS marks the bus, not the core" in a
  string literal, unconditionally, whatever the readings were. Rewritten to
  follow them.
- The verdict also said "every region is disabled". **Region 7 was enabled the
  whole time**, and the map had no address inside it — a map that covered
  everything except the one place where something happens. Four bootrom
  addresses were added and the sentence became a count.

The fourth was arithmetic: `verify.py` kept the map in a dictionary keyed by
address, so the second, clean copy printed in the final report silently
overwrote the corrupted first copy that `check.sh` feeds it — and the
corruption test passed while testing nothing. Both copies are now kept, and
disagreeing with itself is its own failure.

## What is not verified here

- **The SAU/IDAU combination rule is not used and not known.** See
  [One question this does not close](#one-question-this-does-not-close).
- **Nothing was configured.** This says what the bootrom left; it does not say
  what the SAU *could* do if a region were enabled, and no experiment here has
  ever enabled one.
- **`TT` is the architecture's answer, not the bus's.** Candidate 4 shows the
  two disagreeing on purpose: bank 8 is `S=yes nsr=no` to `TT` whether or not
  ACCESSCTRL is refusing it, because ACCESSCTRL is not part of the attribution.
- **One board, one part, one bootrom version.** Region 7's base is this
  bootrom's; another revision may place it elsewhere.
- **Candidate 6 is a fact about `embassy-rp`'s `spawn_core1`**, not a proof that
  no launch sequence could do it. A hand-rolled one is not tested here.
- **The `SG` veneer is still not built.** exp156 promised it, and the promise
  now has a price attached: with the SAU describing nothing, a veneer would need
  the address space repartitioned first.

## Four things to take away

1. **Read the mechanism before you build on the substitute.** Six experiments
   used the right tool for the job and described it with the wrong word, and one
   afternoon of reading registers was all it took to find out.
2. **"Non-secure" is two different claims.** A bus filter that marks traffic and
   an architecture that separates state are both useful and are not the same
   thing. On this part you can have the first without the second, and the second
   is switched off.
3. **The default is Secure, and that is why anything worked.** With every SAU
   region disabled and `ALLNS=0`, the whole address space defaults Secure — so
   core 1 could execute at all *because* it was Secure. A core genuinely in
   Non-secure state would have faulted on its first instruction fetch.
4. **A verdict printed as a string is not a verdict.** Three times in this
   experiment a conclusion was in the firmware before the reading was, and twice
   it was wrong. The ones that survived are the ones that count something.

## Next

**Done in this commit: the word, in five READMEs.** exp156, exp159, exp160,
exp162 and exp163 each carry a note saying which kind of Non-secure they mean
and pointing here. None of their measurements changed.

What is left is the other direction: **enable a region and see what moves.**
Everything above is what the bootrom left. The first SAU region this repository
writes itself would be the first time the architecture's own wall does anything
on this board — and the thing to be careful about is that a region has to cover
memory this firmware is not currently executing from, or the experiment
repartitions the ground it is standing on.

That is also the only road back to exp156's unkept promise. An `SG` veneer needs
a Non-secure-Callable region to live in, and this chip has none.
