# exp136-joining-halfway — a boundary you can join halfway

[exp128](../exp128-reassemble-by-hand/) took the message boundary from USB
itself: a message ends at the first packet shorter than 64 bytes.
[exp135](../exp135-a-packet-with-no-bytes/) paid what that costs — one
unterminated message silently swallows the next, and only a program holding the
interface can send the packet that ends it.

So the boundary moves up, out of the transport and into the bytes. Two ways to
do that, and one question that separates them:

> Join the stream halfway. Which one can find the next boundary?

| | How it marks a boundary | How it resynchronises |
| --- | --- | --- |
| **length-prefix** | `0xA5`, a 16-bit length, the payload | hunts for the magic byte — which a payload can contain. **By luck.** |
| **COBS** | reserve `0x00`; encode so the payload can never contain it | the next `0x00` is always a real boundary. **By construction.** |

Needs: any RP2350 board, and the exp102 toolchain. No browser, and nobody in
the room. The comparison itself needs no board at all.

## The finding, and it is not the one this was set up to expect

`crates/framing` cuts an encoded stream at **every offset**, hands the tail to
a decoder that has just arrived, and counts what it made of it. 28 messages,
about 550 bytes, every cut:

```text
               cuts  clean  invented  lost  worst wait
length-prefix   581    573         3     5  Some(78)
cobs            553    525         0    28  Some(77)
```

**Length-prefix loses fewer messages.** It also delivers three that were never
sent. COBS delivers nothing it was not given and drops one message per boundary
it cannot recognise.

So the trade is not "which recovers better". Both recover inside one message.
The trade is **loss against fabrication**, and they are not equally bad: a
dropped message announces itself by being missing, while an invented one is
indistinguishable from a real one and the receiver acts on it.

### Where the invented messages come from

One payload in the corpus spells a plausible header — `a5 05 00` then five
bytes — which is a thing payloads are entirely free to do. A decoder that joins
the stream inside it reads *magic, length five* and hands up `abcde`:

```text
whole frame:   a5 08 00 │ a5 05 00 61 62 63 64 65     → one 8-byte message
joined 3 in:            │ a5 05 00 61 62 63 64 65     → "abcde", from nowhere
```

Three different cut offsets produce that same phantom, and the test asserts it
by name rather than by count.

### What COBS actually buys

Not "no phantoms". Take a suffix of a COBS frame that happens to start on a
code byte and it is a valid frame in its own right — the tail above is exactly
the encoding of `abcde`. What COBS buys is that **a sound recovery exists**:
because the delimiter cannot occur inside a payload, a decoder can wait for one
and know it has a real boundary. Length-prefix offers no such option; there is
no byte that means "boundary", so no amount of caution makes it safe.

The 28 lost messages are the price of taking that option — one per cut that
lands on a boundary, because a decoder arriving at a boundary cannot tell it
from arriving in the middle. That is a decision, not a law. An optimistic COBS
decoder would deliver those 28 and would be the one inventing messages.

## Two builds, one source

```sh
cargo build --release                  # length-prefix
cargo build --release --features cobs  # COBS
```

The scheme is a type alias in the crate, so `src/main.rs` names neither of
them, and `check.sh` fails if it ever does.

## The code IS the walkthrough

- [`../../crates/framing/src/lib.rs`](../../crates/framing/src/lib.rs) — both
  encoders, both byte-fed decoders, and `Start::joined` — the one function
  whose two implementations differ, which is the whole finding in miniature.
- [`../../crates/framing/src/resync.rs`](../../crates/framing/src/resync.rs) —
  the sweep. Its own first version scored a decoder that missed one message and
  then delivered every later one perfectly as having failed every time; the
  comment where that was fixed is worth reading before trusting any measurement
  of your own.
- [`src/main.rs`](./src/main.rs) — the firmware, which feeds every byte it
  receives to the deframer and never asks where a packet ended.

## Two ways to do it

```sh
./run.sh      # guided: the sweep, then both builds against the same bytes
./check.sh    # verdict: works against whichever build is flashed
```

## Do this, in order

Everything here works from a `.zip` built by `pack.sh` alone. **Two firmware
images and two terminals.** The test is not "does it work" — both work — it is
what each one does when you join the stream halfway, which is what a reader
attaching to a running system always does.

WHAT YOU NEED
  * A Raspberry Pi Pico 2 and a USB data cable.
  * Ubuntu. `cat`, `stty` and `printf` are already there. No `yi26`.
  * Two terminal windows.

**Put the port in raw mode before sending anything.** These are binary frames;
a cooked terminal will mangle them and you will spend an afternoon on it:

    stty -F /dev/ttyACM0 raw -echo

1. UNPACK IT.

       unzip exp136-joining-halfway.zip
       cd exp136-joining-halfway
       ls firmware/

       exp136-cobs.uf2            a delimiter: one byte value that cannot appear inside
       exp136-length-prefix.uf2   a header: magic byte, then how many bytes follow

2. FLASH THE LENGTH-PREFIX BUILD. **[HUMAN STEP]** Hold BOOTSEL, plug in, let
   go:

       cp firmware/exp136-length-prefix.uf2 /media/$USER/RP2350/

3. LISTEN IN THE FIRST TERMINAL.

       sleep 6
       stty -F /dev/ttyACM0 raw -echo
       cat /dev/ttyACM0

   Expect `exp136 up. deframer: length-prefix, max payload 128 bytes.`

4. SEND ONE CLEAN FRAME, FROM THE SECOND TERMINAL. The header is three bytes:
   magic `A5`, then the payload length as two bytes, low first.

       printf '\xa5\x05\x00hello' > /dev/ttyACM0

       [  111784 ms] msg #1: 5 bytes: hello

5. NOW JOIN HALFWAY. Send three bytes of somebody else's message, then a
   whole one, in a single write — exactly what a reader sees when it attaches
   to a stream already running.

       printf 'llo\xa5\x05\x00world' > /dev/ttyACM0

       [  114786 ms] msg #2: 5 bytes: world
       [  114786 ms]   found after discarding 3 bytes

   **It recovered, and it recovered by hunting for the magic byte.** Which
   works here because no payload happened to contain `A5`. When one does, this
   deframer locks onto a header that is not a header, reads a length that is
   not a length, and delivers a message nobody sent. It resynchronises by
   luck.

6. FLASH THE COBS BUILD AND DO THE SAME TWO SENDS.

       cp firmware/exp136-cobs.uf2 /media/$USER/RP2350/
       sleep 6
       stty -F /dev/ttyACM0 raw -echo
       cat /dev/ttyACM0

   In the other terminal, a COBS frame for `hello` — one length byte, the
   payload, then the zero that ends it:

       printf '\x06hello\x00' > /dev/ttyACM0

       [    8735 ms]   7 bytes discarded, no message — still looking for a boundary

   **The message is gone.** Not corrupted, not delayed — discarded, because
   the deframer attached mid-stream and has no way to know that these seven
   bytes are a whole frame rather than the tail of one. It refuses to guess.

7. SEND THE JOINED-HALFWAY PAIR.

       printf 'llo\x00\x06world\x00' > /dev/ttyACM0

       [   11738 ms] msg #1: 5 bytes: world
       [   11738 ms]   found after discarding 4 bytes

   The junk ends at a zero, the next frame starts after it, and the boundary
   is not a guess: the delimiter is a byte value that **cannot occur inside a
   payload**, so finding one is proof.

8. PUT THE TWO FAILURES SIDE BY SIDE.

       length-prefix   delivered both, and can deliver messages nobody sent
       cobs            lost the first, and cannot deliver one nobody sent

   One loses messages, the other invents them. **Neither is the safe choice in
   general** — a lost message you can detect, an invented one you cannot — and
   that is the trade this experiment exists to make visible rather than to
   settle.

IF IT DOES NOT WORK
  * Everything is discarded — the port is not in raw mode, or the header is
    wrong. Length-prefix wants three header bytes, `A5 len_lo len_hi`, not two.
  * `stty` prints nothing and never returns — ModemManager. Ctrl-C, wait,
    retry.
  * Step 6 delivers `hello` instead of discarding it — then your board saw a
    delimiter before it, and you are not joining halfway. Reflash and try
    again without reading first.

## Expected output

Captured from a Pico 2. The **length-prefix** build, straight after flashing:

```text
[      37 ms] exp136 up. deframer: length-prefix, max payload 128 bytes.
```

The eight-byte payload that spells a header, sent whole, then its own interior
sent on its own:

```text
$ yi26 send '\xa5\x08\x00\xa5\x05\x00abcde'
[    1822 ms] msg #1: 8 bytes: ...abcde

$ yi26 send '\xa5\x05\x00abcde'
[    4930 ms] msg #2: 5 bytes: abcde
[    5037 ms] idle: length-prefix — 2 messages from 2 packets, 0 bytes discarded
```

`msg #2` is the middle of `msg #1`. The board cannot tell, and **the discard
counter stays at zero** — there is no signal anywhere that a guess was made.

The **COBS** build, same board, the first frame it is ever sent:

```text
[      37 ms] exp136 up. deframer: cobs, max payload 128 bytes.

$ yi26 send '\x06hello\x00'
[    1505 ms]   7 bytes discarded, no message — still looking for a boundary

$ yi26 send '\x06hello\x00'
[    4613 ms] msg #1: 5 bytes: hello
[    5037 ms] idle: cobs — 1 message from 2 packets, 7 bytes discarded
```

It threw the first one away rather than guess, said so, and has been exact ever
since. That single number — 7 against 0 — is the whole difference between the
two builds, arriving on hardware.

`./check.sh` against the length-prefix build:

```text
PASS  toolchain present (cargo, elf2flash)
PASS  the framing crate's tests pass (both schemes, every cut, no board)
PASS  length-prefix compiles and converts to UF2 (46592 bytes)
PASS  cobs compiles and converts to UF2 (46592 bytes)
PASS  the firmware names no scheme — the crate's type alias decides
PASS  board is running exp136
PASS  the board says which build it is, in a line that repeats: length-prefix
PASS  a whole frame arrives as its payload, and nothing else
PASS  the 8-byte payload that spells a header arrives whole
PASS  the interior of a frame is delivered as a message — the board cannot tell
PASS  the next whole frame is correct — both schemes recover
PASS  length-prefix discarded nothing — it never knew it had guessed
```

and against the COBS build, the last line becomes the other side of it:

```text
PASS  the board says which build it is, in a line that repeats: cobs
PASS  COBS threw away the first frame it ever saw (7 bytes) rather than guess
```

## A line that repeats, because exp134 said so

The firmware names its scheme in the **idle** line, not only in the boot
banner. It was written the other way first, and `check.sh` answered
`SKIP  the boot line has aged out of the log queue` on a board that had been up
for two minutes — [exp134](../exp134-the-log-nobody-reads/)'s sixteen-line
queue, dropping the oldest first, arriving as a practical consequence rather
than as a lesson. A capture that cannot say what produced it is not evidence,
so the line that says it is the one that repeats.

## What this experiment does not claim

**Neither scheme here has a checksum.** A frame layer without one cannot tell a
corrupted payload from a real one, which in most protocols matters more than
resynchronisation. The comparison is deliberately narrow.

**It does not say to use COBS.** Independent prior work on this ground — a
protocol carrying signed transactions, hardware-verified over both CDC and a
vendor interface — shipped magic + length, and was right to: its frames had to
stay byte-identical across three implementations and two transports, and a
scheme whose encoded length depends on the payload's contents makes that harder
to reason about. What it did not have was a test for the payload that spells a
header. That test is the deliverable here.

## Make it yours

1. Put `0xA5` in a payload and run the sweep again. The invented-message count
   moves, and which offsets produce it will surprise you.
2. Make the COBS decoder optimistic — `Start::fresh` instead of `joined` — and
   re-run. The 28 losses go to zero and the invented count stops being zero.
   That is the same trade, moved by one line.
3. Add a two-byte checksum to either scheme and sweep again. Watch what it does
   to the invented count, and what it does not do to the lost one.
4. Send a frame whose declared length is `0xFFFF`. The decoder drops three
   bytes and re-hunts — and if a real magic byte was among those three, it went
   with them.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `msg #1` never appears on the COBS build | The first frame after boot is discarded by design | Send it again; the second one arrives |
| Nothing arrives at all | The bytes are not a frame — a bare line is not one | `yi26 send '\xa5\x05\x00hello'`, escapes included |
| `check.sh` says the build cannot be established | The firmware is not exp136, or the log is not being read | `yi26 port --json` |
| The message arrives with junk in front | A previous partial frame is still being assembled | Send a whole frame; both schemes recover inside one message |

## Next

Nothing on the framing road. exp128 asked where a boundary comes from, exp135
paid what the transport's own boundary costs, and this one built two out of
nothing and measured what each costs a reader who arrived late. What remains
under [Planned](../README.md#planned) stands alone.
