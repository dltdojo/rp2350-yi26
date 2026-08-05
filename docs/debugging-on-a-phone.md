# Debugging on somebody else's phone

Written after two experiments — [exp146](../experiments/exp146-a-page-that-writes-flash/)
and [exp147](../experiments/exp147-two-firmwares-one-phone/) — were built on a
desktop and verified on a phone that the person writing the code never touched.
Eleven exchanges, three bugs in the pages, two wrong instructions, and one
finding nobody was looking for.

This is what that loop is actually like, and how to build for it. It is not a
retrospective: every rule here is one that would have saved a round trip.

## The shape of the loop

```text
   the machine with the code            the phone
   ────────────────────────             ─────────
   builds the .uf2                      opens a local HTML file
   writes the page                      taps a native dialog nobody else sees
   reads screenshots            <────   sends screenshots
   cannot see: the board, the LED,      cannot see: the source, the compiler,
   the browser, the dialogs             the error console
```

Nothing crosses that gap except a `.zip` in one direction and screenshots in the
other. Both are slow, and one of them is lossy in ways that decide the design.

## What a screenshot can and cannot carry

**It carries** whatever the page has already put on screen, as text, in a region
that does not scroll away.

**It does not carry** the native device chooser — Android will not screenshot
it — the LED, the board's enumeration state, or anything the page decided not
to print. In this session the person could not photograph the dialog that was
the entire problem twice over.

So the first rule is not about pages at all:

> **Never design a step whose result the person has to describe in prose.**
> Ask for a screenshot of something the page printed, or for one glance at a
> physical indicator with two obvious states.

"Which of the three entries did you pick?" is unanswerable. "Is the LED fast or
slow?" is answered in half a second and cannot be transcribed wrongly.

## Make the page the instrument

The page is the only thing on the far side that can speak. It has to say more
than whether it worked.

**Log what you received, not only what you concluded.** exp146's page printed
the device it had been handed — name, VID:PID, serial, and every interface class
— and that turned an unanswerable question into a line of text:

```text
picked: RP2350 Boot — 2e8a:000f, serial 7FCAF01F5613A90C
  interface 0: class 0x08
  interface 1: class 0xff  <- PICOBOOT
```

**Log it *before* the call that can fail, not after.** The first version of that
page logged the picked device after `open()` succeeded, so it printed nothing on
exactly the two attempts that failed. A diagnostic that only appears on success
is not a diagnostic. That cost one round trip.

**Print quantities that separate hypotheses.** When exp147's page found no
firmware where firmware certainly was, one line settled it:

```text
B at 0x10011000: erased — nothing installed here
  4096 bytes read, starting ff ff ff ff ff ff ff ff
```

`4096 bytes read` said the transfer worked. `ff ff ff ff` said the flash was
blank rather than unreadable. Two hypotheses died in one screenshot. Before that
line existed, the same failure took two exchanges to localise.

**Put a build marker on the page.** `pflash.html · build 2026-08-05`. A phone
caches aggressively and a `content://` file is opened from wherever the user
saved it; without a marker, "did you get the new one?" becomes a question.

## Error messages are the interface

On a desktop you read the message and look at the code. Here the message *is*
the debugging session, and a wrong one costs a full exchange plus whatever the
person does in the meantime.

**A message that names the wrong cause sends somebody in a circle.** exp147's
page said *"Neither half has a versioned image. Install the pair with
pflash.html first"* to somebody who had installed it ninety seconds earlier. The
person's reply was the right one — *"問題是再刷 pflash 不是重複之前錯誤了嗎？"*
— and the message, not the board, was what needed fixing.

**Distinguish causes rather than reporting a failure.** Two different things
wear the same exception:

| Symptom | What it means | What to say |
| --- | --- | --- |
| one chooser entry of several fails to open | a stale entry | pick a different one; the live one asks for permission |
| **every** entry fails to open | there is no live one — the board is not in that state at all | check the LED; use `bootsel.html` first |

The page counts the failures in a row now, because the count is what tells them
apart. It got that right the first time it was tried, and the person's next
message was a correct diagnosis rather than a question.

**Never promise a safety you have not verified.** exp147's button said it
*"writes nothing at all"*. The page wrote nothing; the **ROM** erased half a
megabyte of firmware. Saying "this page does not write" and meaning "nothing
gets written" is the kind of error that only shows up on somebody else's board,
and the person holding it has no way back.

## Trust the instrument you built

The worst procedure in this record was written by somebody who had already
solved the problem and then did not notice.

exp150's LED has four states, and the fourth exists precisely so that nobody has
to read a log:

```text
fast   an address was leased, and NO request has been served
solid  a browser got the page
```

When the page would not load, the person was asked for the LED — and answered
**"fast"**. That was the complete answer. It said the board had a link, had
leased an address, and had served nothing, which is exactly what the whole
question was.

They were then asked to unzip a second package, open `log.html`, tap through a
device chooser, connect it, keep that tab alive, open a second tab, type an
address, wait for a timeout, switch back, and screenshot. Six steps, one
exchange, **and the log said `0 request(s) served`** — the same fact the LED had
already reported, in a form that took ten times as long to obtain.

Their reply was *"除錯過程太複雜"*, and it was the right correction.

> **Before asking for a diagnostic, check whether the readout you already built
> answers the question.** If it does, the extra steps buy confirmation, and
> confirmation is not worth a round trip through somebody else's hands.

The trap is specific to this arrangement: the person who designed the LED is not
the person looking at it, so the designer reaches for the tool *they* would use
— a log — and forgets that they already spent effort making that unnecessary.
An instrument you do not trust is an instrument you should not have built.

## The round trip is the expensive thing

You cannot iterate. So everything that *can* be checked without the phone has to
be checked harder than usual — and the trap is that it is easy to check
something adjacent to what actually runs.

**Extract the page's own code and run it.** Both pages have their `<script>`
block pulled out by `check.sh`, syntax-checked with `node --check`, and their
pure functions run against fixtures the real toolchain produced. That caught
things. It also missed things, in a way worth naming:

> **A test whose input is bigger than the code's input is not testing the code.**

`check.sh` fed `findVersion` a whole 4096-byte sector and it found the version.
The page read **256 bytes** from the board and found nothing, because the block
it looks for starts at `+0x114`. Seventeen `PASS` lines, and the page could not
do its one job. Two exchanges.

**Fix every call site, and make the guard match the bug, not the line.** After
that was fixed in one place, the read-back inside the *switch* was still 256
bytes — so the write succeeded and the verification reported failure, which is
the one direction a verification must never fail in: it sent the person to
reinstall a half that was fine. The guard now fails on *any* read with a literal
length, because the bug was never about a particular line.

## Phone hazards, each with what it looked like

| Hazard | How it presented |
| --- | --- |
| The chooser lists the same board several times | three entries; two failed `open()` with `SecurityError: Access denied`, the third worked. **The live one is the one that makes Android ask for USB permission** — nothing in the names says which |
| Native dialogs cannot be screenshotted | "出現三個裝置可以選，不知道選哪個，不能截圖" |
| `accept=".uf2"` greys the file out | Android has no MIME type for `.uf2`; the file input must accept everything and validate in the page |
| A `content://` page is its own origin | permissions do not carry between the pages you send; expect one grant per page |
| **Sleep takes the board out of BOOTSEL** | see below — this one changes the shape of the instructions |

### The sleeping phone

**A board does not sit in BOOTSEL safely on a phone.** If the screen sleeps and
the port is power-cycled, the board resets — and a reset boots a firmware, it
does not return to the bootloader. Nothing announces it. The next page simply
finds a chooser full of dead entries, which looks exactly like a broken page.

This was raised by the person running the experiment, not measured here, and it
fits every failure in that run that was not a bug in a page. It is a hazard to
design around:

- **Pair the step that enters BOOTSEL with the step that needs it.** Not
  "step 2: BOOTSEL … step 5: press the button". `bootsel.html` and the action go
  together, with no reading in between.
- **Never leave the board in BOOTSEL while somebody reads.** Reading is exactly
  when a screen sleeps.
- **Prefer an indicator that survives it.** An LED does not care whether the
  phone is awake, and it reports state instantly with no transcription. exp147
  chose a fast/slow blink as its readout for a different reason — a person with
  no toolchain — and it turned out to be the only instrument in the experiment
  that a sleeping phone could not interrupt.

## Designing the sequence

**Ask for the state first, with an instrument that can see all of it.** exp146's
step 0 told the person to identify the board with `inspect.html`, which filters
for `1209:0001` — the *application* firmware. A board in BOOTSEL is
`2e8a:000f`, so it appeared nowhere, and the first step of the first run failed
on a page that was working perfectly. Check what your identifying tool can
actually see before making it step 0.

**Give a decision tree keyed on what they can see, not on what they must do.**

```text
LED fast   -> slot A is running; the switch took
LED slow   -> slot B is running
no blink   -> nothing is running; hold BOOTSEL while plugging in
no drive   -> not in BOOTSEL
```

Three lines like that resolve in one exchange what a paragraph of instructions
resolves in three.

**Make failure free, and say so.** Both pages refuse before they write — wrong
base address, no boot block, wrong chip family — and refuse to reboot unless a
read-back matches. Telling the person that up front changes what they are
willing to try, and trying things is the only way this loop converges. "Picking
the wrong entry costs nothing" is what let somebody work down a list of three
until one worked.

## What it cost

Eleven exchanges for two experiments. Three bugs in the pages, all of them in
code that `check.sh` was green on. Two wrong instructions from the person who
could not see the board. One finding — that a flash update boot of an image with
no `TBYB` flag is a completed update rather than a trial — which surfaced
*because* somebody pressed a button, watched an LED, replugged a board, and said
"這樣不對吧".

The last one is the argument for the whole arrangement. A person who cannot see
the source, working an instrument the author cannot see, will find things the
author's tests cannot — and every rule above is about making the report they can
send back worth as much as the observation they just made.
