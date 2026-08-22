# exp165 — who gets the last word

[exp164](../exp164-the-wall-nobody-read/) read the SAU and left one question
open on purpose. This one writes a region — the first this repository has ever
written — and uses it as an instrument to narrow that question from three
possible answers to two.

**Our Non-secure region is honoured and named in SRAM, and silently overruled in
the bootrom and at `SIO_NS`.** Two of four probed ranges take the SAU's word;
two do not, and nothing in the log says which unit refused them.

The second experiment on the [attribution road](../README.md#the-attribution-road).
Nothing here executes, accesses, or enters Non-secure state.

## The question this inherits

exp164 found the SAU **enabled**, with one of its eight regions in use — region
7, `0x46a0..0x7fff`, the upper bootrom, marked Non-secure by something that ran
before any firmware did. Then it asked `TT` about eighteen addresses and got one
colour back: **every one Secure, none Non-secure-readable**, including
`0x00005000`, which sits *inside* region 7.

It could not settle that, and said so:

> So either the IDAU overrides the SAU there, or the descriptor means something
> other than it looks like. Settling it needs the Armv8-M Architecture Reference
> Manual, which this experiment does not have, and guessing would turn an open
> question into a check.

That was the right call and it is not the only move available. `cortex-m`'s own
documentation for `sau_region()` lists **four separate reasons** the instruction
returns no region number, and exp164's reading is consistent with all of them:

```text
/// Returns None if:
///   * SAU_CTRL.ENABLE is set to zero
///   * the SREGION field does not match any enabled SAU regions
///   * the address matches multiple enabled SAU regions
///   * the address is exempt from the secure memory attribution
///   * TT was executed from the Non-secure state
```

So "the IDAU overrules the SAU in the bootrom" was a **hypothesis**, and this
repository had never read the IDAU at all. Three explanations were alive:

1. something outside the SAU decides attribution there,
2. the **reporting path** is silent everywhere and region 7 is not special,
3. the address is architecturally exempt from attribution.

**A region written over memory nothing has any reason to override separates (2)
from the other two, and needs no manual to do it.** If our own region is named,
the reporting path works, and (2) is dead.

## What this cannot do, said before the results

It never executes anything, never enters Non-secure state, and never makes an
access that is meant to be refused. **It can therefore show the SAU *saying*
something and can never show the SAU *refusing* anything.**

exp156's sentence, turned around and pointed here: *a boundary you did not build
is not a boundary you measured.* An attribution nothing tries to violate has
been read, not tested. A refusal needs Non-secure code, which needs an NSC
region, a hand-written `SG` veneer, banked stack pointers and a second vector
table — a subsystem rather than an experiment, and
[the attribution road](../README.md#the-attribution-road) is where that line is
drawn.

## The safety argument, and it is the whole design

Marking a range Non-secure is harmless to Secure code that only *reads* it:
Secure state may access Non-secure memory, and the reverse is what the
architecture forbids. What is never harmless is marking memory a Secure core is
**fetching instructions from** — that is a SecureFault on the next fetch and a
dark board with no log to say why.

So the four ranges this firmware is willing to write a region over are ones it
neither executes from nor keeps anything in, and that is enforced twice:

| | |
| --- | --- |
| at runtime | `may_write` refuses any region overlapping XIP flash, the main 512 KB of SRAM, the USB DPRAM or the System Control Space |
| at build time | `check.sh` parses `PROBES` and `FORBIDDEN` out of the source and compares them numerically, so the two lists cannot drift apart |

Each probe is enabled, asked, and switched off with **no `await` in between**, so
the window in which the map is altered contains no logging, no USB and no timer
work. And the SAU is core state: it resets to nothing. Unlike
[exp154](../exp154-somewhere-to-put-a-key/)'s subject, there is no way for
anything here to be permanent.

## Two things read before any of this was designed

| fact | how | what it changed |
|---|---|---|
| `cortex-m` ships `SAU::set_region`, and it encodes **Secure** as a descriptor with `RLAR.ENABLE = 0` | read the crate | ← "make this Secure again" and "switch the region off" are the same write, which is why candidate 5 can undo candidate 3 with no separate path |
| the architecture requires `DSB` + `ISB` after configuring the SAU | Armv8-M convention, and the reason is mechanical | ← without them a `TT` issued straight afterwards may be answered from the old configuration, and **"the SAU's word was not honoured" would be indistinguishable from "it had not landed yet"** — which is the most interesting of the three outcomes this experiment can report. `check.sh` counts the barriers |

## Why there is no `breadcrumb` here

Six of the seven experiments before this one run one candidate per boot, because
their candidates can kill a boot: a demoted core faults, a launch blocks
forever, a signature runs the stack 423 KB deep. **Nothing in this firmware can
die.** It performs no access through the regions it writes and executes nothing
from them.

So it runs in a single boot — which is also what made it cheap to iterate on.

## The eight candidates

| # | what it does | graded on |
|---|---|---|
| 1 | asks `TT` about exp164's eighteen addresses | **all eighteen Secure and not NS-readable** — exp164's reading, re-taken |
| 2 | writes region 1 over SRAM bank 9, Non-secure | the registers read back as written **and the map is handed back** |
| 3 | asks `TT` about bank 9 with the region on | *ungraded* — this is the open question |
| 4 | asks `TT` about the other seventeen, region still on | none of them moved |
| 5 | switches the region off and asks again | the answer returns to candidate 1's |
| 6 | the same range, marked Non-secure-Callable | *ungraded* |
| 7 | reads `ACCESSCTRL.SRAM[9]` either side of the write | the bus filter did not move |
| 8 | the same region over four ranges in turn | *ungraded* — this is the map |

Three candidates carry no expected outcome, and `check.sh` fails if any of them
ever acquires one. That is exp162's lesson: **an expected answer in a matrix is
an answer the run cannot contradict**, and exp164 needed it twice.

## The result

One run on a Pico 2, 2026-08-22. All five graded candidates as expected.

### The SAU's word is taken, and reported

```
  bank 9, region off     0x20081000 S=yes nsr=no  sau=-1 idau=-1 raw=0x004c0000
  bank 9, ours NS        0x20081000 S=no  nsr=yes sau=1 idau=-1 raw=0x003e0100
```

One register write moves an address out of Secure, and `TT` **names the region
that did it**. Nothing else on the eighteen-address map moved, and switching the
region off returned bank 9 to `0x004c0000` exactly.

**So the reporting path works, and hypothesis (2) is dead.** exp164's region 7
is silent for a reason belonging to that address, not to `TT`.

### And where it is not taken, nothing says so

```
  SRAM bank 9       0x20081000 S yes->no  nsr yes sau=1 MOVED   back=ok
  SRAM bank 8       0x20080000 S yes->no  nsr yes sau=1 MOVED   back=ok
  bootrom below r7  0x00001000 S yes->yes nsr no  sau=-1 unmoved back=ok
  SIO_NS alias      0xd0020000 S yes->yes nsr no  sau=-1 unmoved back=ok
```

The identical region, moved from one range to another, is **honoured twice and
overruled twice** — and the two ranges that overrule it report no error, no
region, and no reason. `SFSR` is still zero: nothing was faulted, nothing was
refused, the write simply did not mean anything there.

That is the first evidence on this road that **a second attribution unit
exists**, and it is deliberately not named. The IDAU is one candidate;
`cortex-m` lists an architectural exemption as a separate one; this firmware
cannot tell them apart and neither can `verify.py`, which prints the question as
`OPEN` instead of deriving a rule it has no manual for.

**Three hypotheses became two, and the surviving pair is now localised to two
address ranges instead of to the whole chip.**

### exp156's veneer has somewhere to live

```
  bank 9, ours NSC       0x20081000 S=yes nsr=no  sau=1 idau=-1 raw=0x004e0100
```

Marked Non-secure-Callable, the same range answers with a **third** attribution:
Secure like the baseline, not Non-secure-readable — and yet it names region 1,
which the baseline never did. NSC is describable on this part.

exp156 promised a hand-written `SG` veneer and exp164 attached a price to it:
*with the SAU describing nothing, a veneer would need the address space
repartitioned first.* The repartitioning is now known to be possible in SRAM,
and the veneer is still not built.

### The two walls are independent, measured from both sides

```
  ACCESSCTRL.SRAM[9] pre=0x000000ff ours-NS=0x000000ff post=0x000000ff
```

exp164's candidate 4 shut a bank in ACCESSCTRL and showed the SAU did not move.
This is the same question from the other side. Neither mechanism can see the
other, and that is now a measurement rather than an assertion — which is worth
having, because five experiments on this road spent their lives calling one of
them by the other's name.

This firmware **never writes ACCESSCTRL at all**; `check.sh` fails if the
`0xACCE` key so much as appears in the source, because a firmware that can write
the register is a worse witness to it holding still.

## What it cost to find out

Four flashes, and three of them went to the instrument.

- **The first run left the region enabled at the end of candidate 2.** Every
  later "baseline" was therefore measured through a map the firmware had already
  changed, and the verdict came out **backwards**: it reported a wall that was
  working as a wall that did nothing. Candidate 5's put-it-back control is what
  caught it, by failing. Handing the map back is now graded, later candidates
  compare against candidate 1's reading rather than a fresh one, and
  `BANK9_IDX`'s correctness is a compile-time assert.
- **`usb-log` dropped forty-nine lines** in the middle of candidate 1, including
  readings the whole experiment was written to take. The drain stopped for about
  600 ms and the sixteen-deep queue filled behind it. The pace is now 60 ms a
  line, which absorbs nearly a second of outage.
- **The report printed once and then the board went idle**, so `check.sh` hung
  waiting for a verdict that had scrolled past at second eight — and so would
  any person who plugged in late. It now repeats every fifteen seconds **and
  reprints the three readings the verdict rests on**, because a conclusion whose
  evidence is in a scrollback nobody has is a conclusion a reader must take on
  trust.

The pattern in all three is the same one exp164 named: **the instrument, not the
subject.** None of them was a wrong idea about the chip.

## What is not verified here

- **Nothing was refused.** This is the limit stated at the top, and it is the
  whole difference between this experiment and one about TrustZone.
- **The unit that overrules the SAU is not named.** IDAU or architectural
  exemption; `TT` reports `idau=-1` everywhere, which the crate documents as
  consistent with an IDAU that decides and declines to number its regions.
- **Only four ranges were probed**, and they were chosen for being safe rather
  than for covering the address space. The boundary between honoured and
  overruled is not mapped, only shown to exist.
- **One board, one part, one bootrom version.** Region 7's base is this
  bootrom's; another revision may draw the bootrom's line elsewhere.
- **Nothing was enabled and left enabled.** Every region this firmware writes is
  switched off in the same candidate, and the final report prints `RLAR=0` to
  prove it. What a *persistent* Non-secure region does to a running firmware is
  not measured here.
- **The `SG` veneer is still not built**, and now has one fewer excuse.

## Running it

```console
cd experiments/exp165-who-gets-the-last-word
cargo build --release
elf2flash convert -b rp2350 \
  target/thumbv8m.main-none-eabihf/release/exp165-who-gets-the-last-word \
  target/exp165.uf2
yi26 bootsel && yi26 pflash target/exp165.uf2
yi26 log --seconds 30          # one boot, about nine seconds, then it repeats
./check.sh                     # 30 checks
```

Nothing needs a hand on the board once it is flashed, and the run ends
reflashable with no watchdog to disarm.

To check a log you already have, on any machine, with nothing installed:

```console
python3 verify.py < capture.txt
```

`verify.py` decodes every `TT` response word **a second time, off the board**,
from the raw value printed beside the fields — because a decode is a claim about
a bit layout, and exp164 shipped one that disagreed with the register it came
from. It also derives that the sweep's own "MOVED"/"unmoved" words follow from
its own readings, and that the verdict follows from candidate 3's. It does
**not** use the Armv8-M rule for combining SAU and IDAU attribution, and prints
`OPEN` where that rule would be needed, because it has no copy of the manual
either. A log that joins mid-run is checked just as hard on everything it
contains.

## Expected output

Pasted from a real run on a Pico 2, Ubuntu, 2026-08-22. Trimmed for length;
nothing is edited. The full run is checked in as [`capture.txt`](./capture.txt).

```console
[    3878 ms]   r7 RBAR=0x000046a0 RLAR=0x00007fe1 -> 0x0046a0..0x007fff en=1 nsc=0
[    4599 ms]   SRAM bank 9            0x20081000 S=yes nsr=no  sau=-1 idau=-1 raw=0x004c0000
[    5020 ms]   all 18 Secure and not NS-readable: yes; 1 region(s) enabled
[    5080 ms] candidate 1 -> as expected

[    5200 ms]   r1 RBAR=0x20081000 RLAR=0x20081fe1 -> 0x20081000..0x20081fff en=1 nsc=0
[    5320 ms]   region switched off; map handed back: yes
[    5380 ms] candidate 2 -> as expected

[    5500 ms]   bank 9, region off     0x20081000 S=yes nsr=no  sau=-1 idau=-1 raw=0x004c0000
[    5560 ms]   bank 9, ours NS        0x20081000 S=no  nsr=yes sau=1 idau=-1 raw=0x003e0100
[    5620 ms]   the TT answer MOVED when our region went on

[    5801 ms]   0 of 17 other addresses moved while ours was on
[    6101 ms]   back to candidate 1's answer: yes
[    6341 ms]   bank 9, ours NSC       0x20081000 S=yes nsr=no  sau=1 idau=-1 raw=0x004e0100
[    6401 ms]   NSC vs NS: different (0x004e0100 vs 0x003e0100)
[    6581 ms]   ACCESSCTRL.SRAM[9] pre=0x000000ff ours-NS=0x000000ff post=0x000000ff

[    6821 ms]   SRAM bank 9       0x20081000 S yes->no  nsr yes sau=1 MOVED back=ok
[    6881 ms]   SRAM bank 8       0x20080000 S yes->no  nsr yes sau=1 MOVED back=ok
[    6941 ms]   bootrom below r7  0x00001000 S yes->yes nsr no  sau=-1 unmoved back=ok
[    7001 ms]   SIO_NS alias      0xd0020000 S yes->yes nsr no  sau=-1 unmoved back=ok
[    7062 ms]   2 of 4 ranges moved; 2 named our region

[    7722 ms]   our region r1 left RBAR=0x00000000 RLAR=0x00000000 en=0
[    7782 ms]   SFSR before=0x00000000 after=0x00000000 - no SecureFault recorded
[    7902 ms] VERDICT:
[    7962 ms]   the SAU's word is honoured AND reported: TT named region 1.
[    8022 ms]   so exp164's region 7 reads sau=-1 for a reason belonging to
[    8082 ms]   that address, not to the reporting path. Something else has
[    8142 ms]   the last word in the bootrom, and this is the first sight of it.
[    8322 ms]   2 of 4 probed ranges honoured our word; 2 named ours
[    8382 ms]   NOT MEASURED: nothing was refused. This firmware never entered
[    8442 ms]   Non-secure state, so every line above is what the SAU SAYS.
```

`./check.sh` on the same board:

```console
PASS  no probe overlaps memory this firmware runs out of (CLEAR 4 probes, 4 forbidden ranges)
PASS  the only RBAR/RLAR writes are region_write's and region_off's
PASS  every region configuration is followed by DSB and ISB
PASS  region 7 (the bootrom's) is never written
PASS  every volatile access targets the SAU block (2 of 2)
PASS  the firmware never writes ACCESSCTRL (candidate 7 only reads it)
PASS  candidates 3, 6 and 8 are ungraded: they are the open questions
PASS  candidate 2 is graded on handing the map back, not just on writing it
PASS  the baseline is candidate 1's, taken before any write (5 uses)
PASS  the baseline index is asserted at compile time, not counted by hand
PASS  the run ends in a repeating report, with no watchdog to disarm
PASS  the repeated report carries the evidence its verdict rests on
PASS  verify.py rejects a self-contradictory attribution (got DISAGREE)
PASS  verify.py rejects a raw response word that disagrees with its fields (got DISAGREE)
PASS  verify.py rejects a sweep verdict that contradicts its own readings (got DISAGREE)
PASS  the recorded capture has no gaps
PASS  all five graded candidates behaved as expected
PASS  SFSR is unchanged: this firmware caused no SecureFault
PASS  the board is left with our region switched off
PASS  the sweep separates the address space (2 of 4 probed ranges honoured our word)
PASS  every reading re-derives off the board from its own raw words
```

## Four things to take away

1. **An open question can be narrowed without the document that would close
   it.** exp164 was right not to guess and would have been wrong to stop. One
   region written where nothing contests it killed one of three explanations,
   and the two that survived are now attached to specific addresses.
2. **A mechanism that is overruled says nothing about it.** The write succeeded,
   the registers read back, `SFSR` stayed zero, and the attribution did not
   move. Silence is what being overruled looks like from inside — which is
   exactly why exp164 could not tell what it was seeing.
3. **"Non-secure" is now three claims on this road, not two.** A bus filter that
   marks traffic (ACCESSCTRL), an architecture that attributes memory (the SAU),
   and something above the SAU that can overrule it. Only the first has ever
   refused anything here.
4. **A conclusion that prints once has not been published.** The board went idle
   after eight seconds and every reader who arrived at second twenty — including
   this experiment's own `check.sh` — saw a healthy board with nothing to say.

## Next

Two roads out, and they are not the same size.

**The cheap one is finishing this map.** Four probes found the boundary exists;
they were chosen for safety, not for coverage. A sweep that walks the whole
address space at region granularity, writing and immediately withdrawing, would
say *where* the SAU stops being the last word — and that is still one flash,
still nothing refused, still nothing that can go dark.

**The expensive one is the veneer**, and it now has one fewer excuse: an NSC
region is describable here. What it still needs is a `global_asm!` `SG` stub, a
linker section to put it in, `MSP_NS`, a second vector table and a `BXNS` — the
subsystem the [attribution road](../README.md#the-attribution-road) draws its
line in front of. It is the only way anything on this road will ever
show the SAU **refusing** rather than saying, and it should be entered with that
sentence written down first.
