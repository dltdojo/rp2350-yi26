# exp134-the-log-nobody-reads — a full queue keeps the oldest, the newest, or none

One firmware that prints one numbered line a second. Built three ways, left
alone for forty seconds with the port closed, and then read. The tick numbers
say what survived:

| Build | What comes back after the silence | Good for |
| --- | --- | --- |
| `drop-newest` *(default)* | the **oldest** sixteen lines, then a jump to now | chasing a crash — the cause is above the last line |
| `keep-recent` | the **newest** sixteen lines | what is it doing *now* |
| `silent-while-idle` | almost nothing, honestly counted | nobody had opened the page yet |

Needs: any RP2350 board with a plain LED, and the exp102 toolchain. No
browser, and no person — `check.sh` reads the answer off a line number.

## Where this came from

A capture in [exp127](../exp127-host-owns-the-led/), taken on a phone. Between
one line and the next the log jumped 125 seconds and said `(+50 lines lost)`.
Two minutes of the board's life were gone, and they were the two minutes
somebody had just spent operating it — because a gap like that ends exactly
where the reader arrives. [exp130](../exp130-the-board-draws/) recorded `+64`
and [exp133](../exp133-a-page-per-job/) `+89`.

## The obvious fix is wrong, and the arithmetic says so

`usb-log`'s queue is sixteen lines. So make it sixty-four.

Sixteen lines at one a second is sixteen seconds; sixty-four is a minute. **The
gap is however long nobody was looking, which has no upper bound.** Four times
the RAM buys four times a number that was never going to be enough. There is no
depth that wins, which is the first thing to be sure of, because it is where
most of this kind of investigation stops.

## The question that had been dodged for thirty-three experiments

`crates/usb-log`'s own module docs said this, and it was wrong:

> It has to give somewhere, and there are only two choices: **wait** for room,
> or **drop** the line.

Waiting really is disqualified — exp104 measured two counter values arriving
21 seconds apart because the caller was parked inside `write_all`. But dropping
hides a second question nobody asked:

> **which** line?

`Channel::try_send` refuses the *new* arrival. So a full queue preserves the
*oldest* sixteen lines — and that was never a decision anybody made. It is what
the container does, adopted by not asking. Evicting the head instead costs the
same RAM, the same time per call, and the same code path, and it hands a late
reader a completely different log.

The third answer is not about fullness at all. While no host has the port open,
queue **nothing**: count every line, keep none, and guarantee that the first
line a reader ever sees describes the present.

Ten lines into a queue of three, from
[`crates/log-policy`](../../crates/log-policy/)'s own tests:

```text
  drop-newest         1  2  3        7 lost
  keep-recent         8  9 10        7 lost
  silent-while-idle    (nothing)    10 lost
```

The last row loses **ten**, not seven. The three the others kept were not worth
keeping, and this policy says so rather than counting a stale line as a
delivered one.

## The counter has to change shape too

This is the part that was not visible until the code was written.

`usb-log` reports loss as a **delta**: `(+50 lines lost)` means fifty since the
last surviving line. That number is rendered into one line's *text*, which is
safe only in a queue that never discards what it has already accepted.

`keep-recent` discards accepted lines by design. A delta written into a line
that is later evicted takes the count with it — and since evictions happen
continuously while idle, the totals a reader sees would be quietly and
unboundedly short. So that build reports a **running total** instead:

```text
[   43038 ms] (23 lines lost so far) tick #43 (keep-recent)
```

which survives eviction because every later line repeats it.

**A delta is not safe in a queue that can throw things away.** That falls out of
the policy rather than being a separate feature, and `check.sh` asserts the
right shape appears for the build that is flashed.

## The flag that cannot be asked for

`silent-while-idle` has to know whether a reader is present, and
`usb_log::log` is an ordinary synchronous function with no access to the USB
sender. It cannot ask. It has to be **told**, by the writer task, which is the
only thing that ever looks at DTR.

That creates a trap worth seeing before you build it:

> If the flag starts `false`, nothing is ever queued, so the writer never
> wakes, so it never looks at DTR, so the flag never becomes true.

A deadlock assembled from two correct halves. It starts `true`, and the cost is
exactly **one line per idle episode**: the first thing said into a closed port
is queued, the writer collects it, finds DTR low, and sets the flag. That held
line is the last thing said before the silence, which is a reasonable thing for
a reader to find waiting for them — and `check.sh` allows at most two, because
more would mean the flag is not being cleared.

### Starting it `true` cost 65,608 bytes of nothing

Worth recording because it looks alarming and is not. `AtomicBool::new(true)`
is the first static in `crates/usb-log` whose initial value is not zero, so it
is the first thing in that crate to land in `.data` instead of `.bss` — and a
non-empty `.data` gets a segment of its own, aligned to 64 KiB. **Every
firmware that depends on this crate has an ELF 65,608 bytes larger than before
this commit**, all of it a hole in the file.

Nothing about the firmware changed. Measured on exp133, built at this commit's
parent and again after it:

```text
ELF      217320  →  282928     the padding
.bss      0x115b0 → 0x115b0    byte-identical: no RAM cost
UF2      140800  →  140800     byte-identical: nothing more is flashed
```

The consequence is for whoever reads the older experiments: their recorded
`compiles (N byte ELF)` lines are all 65,608 bytes short of what a build
produces today, and none of them is stale in any way that matters. See
[the note in the index](../README.md#of-the-two-sizes-in-every-capture-only-one-is-the-firmware).

## Why the decision is a separate crate

`crates/usb-log` cannot be tested. It depends on `embassy-rp`, so it only
compiles for the board, and it has never had a `#[test]` in it.

Every question here — which lines survive, what is counted, what happens at the
boundaries — is answerable with no hardware at all. On a board, reaching one of
these states takes forty seconds of deliberate silence; in
[`crates/log-policy`](../../crates/log-policy/) it takes a function call. Nine
tests, including the one that matters most:

```rust
assert_eq!(simulate(Policy::DropNewest,      false), ([1, 2, 3], 3,  7));
assert_eq!(simulate(Policy::KeepRecent,      false), ([8, 9, 10], 3, 7));
assert_eq!(simulate(Policy::SilentWhileIdle, false), ([0, 0, 0], 0, 10));
```

The crate holds the decision and nothing else. The caller keeps the queue,
counts the loss, and does what it is told — so a policy cannot accidentally
grow the power to stall a caller, and there is no `Admission::Wait` for it to
grow into. A test says so, in as many words.

## The default did not change

Three-quarters of this experiment lives in a crate every firmware here depends
on, so the rule was decided before any of it was written: **the default build
behaves exactly as it always has.** `drop-newest` is what `try_send` already
did, a test asserts the equivalence, and the other two policies are Cargo
features that nothing turns on by accident. They are alternatives rather than
additions, and `usb-log` refuses to compile with both:

```text
error: keep-recent and silent-while-idle are alternatives, not additions:
       one keeps the newest lines and the other keeps none. Choose one.
```

`check.sh` asserts that this build *fails*, because a policy chosen silently is
worse than either.

## The code IS the walkthrough

- [`../../crates/log-policy/src/lib.rs`](../../crates/log-policy/src/lib.rs) —
  the whole decision, forty lines and nine tests. Read this first.
- [`../../crates/usb-log/src/lib.rs`](../../crates/usb-log/src/lib.rs) — `log`
  asks before formatting, and `run` sets the flag the third policy needs.
- [`src/main.rs`](./src/main.rs) — a ticker. Deliberately dull: the firmware is
  not the experiment.

## Two ways to do it

```sh
./run.sh      # guided: all three flashed in turn, four minutes, mostly silence
./check.sh    # verdict: builds all three, measures whichever is flashed
```

## Expected output

Captured from a Pico 2. Each run is the same thing: open the port briefly,
close it, stay away for forty seconds, open it again.

**`drop-newest`** — seventeen old lines, then the jump:

```text
[   72038 ms] tick #72 (drop-newest)
[   73038 ms] tick #73 (drop-newest)
   ... #74 through #87 ...
[   88039 ms] tick #88 (drop-newest)
[  112039 ms] (+23 lines lost) tick #112 (drop-newest)
[  113039 ms] tick #113 (drop-newest)
```

**`keep-recent`** — the jump comes first, then the last sixteen seconds. This
one is from a fresh boot, so the running total starts from nothing:

```text
[    4037 ms] tick #4 (keep-recent)
[   28038 ms] (8 lines lost so far) tick #28 (keep-recent)
[   29038 ms] (9 lines lost so far) tick #29 (keep-recent)
   ... one more lost per second, because one is evicted per second ...
[   43038 ms] (23 lines lost so far) tick #43 (keep-recent)
[   44038 ms] (23 lines lost so far) tick #44 (keep-recent)
[   45038 ms] (23 lines lost so far) tick #45 (keep-recent)
```

The total stops climbing at #44 — that is the moment a reader arrived and the
queue stopped being full. **The counter is the eviction rate, visible in the
log.**

**`silent-while-idle`** — one line, then forty seconds of nothing, then now:

```text
[   63038 ms] tick #63 (silent-while-idle)
[  103038 ms] (+39 lines lost) tick #103 (silent-while-idle)
[  104038 ms] tick #104 (silent-while-idle)
```

`./check.sh` against each of the three:

```text
PASS  the log-policy crate's tests pass (every policy, with no board)
PASS  the default build compiles and converts (44544 bytes)
PASS  the keep-recent build compiles and converts (45056 bytes)
PASS  the silent-while-idle build compiles and converts (44544 bytes)
PASS  the two policies refuse to be combined (compile_error!, not a silent winner)
PASS  one firmware source, three builds (the difference is a constant, not a branch)
PASS  board is running exp134
PASS  the flashed build names its policy on every line (drop-newest)
PASS  the board kept ticking through the silence (last tick #57)
PASS  the silence left a visible gap in the numbering (24 ticks)
PASS  drop-newest reports the loss as a delta on the first surviving line
PASS  drop-newest handed back the OLD lines (17 before the gap, first #6)

PASS  keep-recent reports a running total, which survives eviction
PASS  keep-recent handed back the RECENT lines (1 before the gap, 22 after, last #236)

PASS  silent-while-idle reports the loss as a delta on the first surviving line
PASS  silent-while-idle kept almost nothing (1 stale, 7 live after the gap)
```

## The first line is never evidence, and it cost a failed check to notice

Look again at the `keep-recent` capture. It starts at tick #4 — an *old* line,
under the policy whose entire job is to keep recent ones.

That line is not in the queue. `usb_log::run` takes a line out with
`QUEUE.receive().await` and *then* looks at DTR, so at the moment a port
closes there is always one line already in the writer's hand. It waits there
for as long as the silence lasts and comes out first when a reader appears.
**Every policy has it**, which is exactly why it says nothing about any of
them.

The first version of `check.sh` measured from that line and reported
`keep-recent handed back the old lines` against a firmware that was working
perfectly. The fix was to measure the **gap** instead: how many lines sit
between the held line and the jump, and how many come after it.

| | before the gap | after the gap |
| --- | --- | --- |
| `drop-newest` | **17** — the held line plus a full queue | the live stream |
| `keep-recent` | **1** — the held line, and nothing else survived | 16 + the live stream |
| `silent-while-idle` | **1** | the live stream |

A measurement that cannot tell two policies apart is not a weaker measurement,
it is a wrong one, and the only reason this was caught is that the firmware it
accused was known to be right.

## Make it yours

1. Raise `QUEUE_DEPTH` to 64 and run `./check.sh` again with the default build.
   The gap shrinks by 48 seconds and the shape is identical. That is the
   experiment's first claim, felt rather than read.
2. Flash `keep-recent`, leave it overnight, and connect. The running total is
   in the thousands and every line still carries it. Then work out what a delta
   would have reported, and why.
3. Delete the `READER_PRESENT.store(true, ...)` in `usb_log::run` and build
   `silent-while-idle`. The log goes permanently silent — you have built the
   deadlock the initial value exists to prevent.
4. Add a fourth policy: keep the first four lines *and* the newest twelve. It is
   about six lines in `log-policy` and it needs no board to test. Then decide
   whether it is worth the sentence it costs to explain, which is the actual
   question.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| No `tick #` lines at all | Another program holds the port | `yi26 doctor` names it; a browser tab counts |
| `check.sh` says the numbers look like the other policy | The board is running a build you did not think it was | Every tick line names its own policy — read one |
| The silence produces no loss marker | The idle window was shorter than the queue | 16 lines at one a second; `IDLE` must comfortably exceed that |
| Both features enabled and it will not build | That is the check working | Choose one |

## Next

Nothing on this road. The queue is now a decision rather than a default, and
the remaining item it was blocking — the framing road — is under
[Planned](../README.md#planned).
