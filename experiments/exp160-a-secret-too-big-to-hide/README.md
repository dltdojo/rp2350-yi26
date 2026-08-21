# exp160-a-secret-too-big-to-hide — ML-DSA-65 behind the same wall

The fourth experiment on the [signing road](../README.md#the-signing-road), and
the one the road asked for in one line: *swap the crate for ML-DSA-65 and
measure*. **Does a post-quantum signature still fit the update road? A "no" is a
finding.**

It is not a no, and it is not a yes. Code size was never the problem, and the
thing that does not fit is the one nobody had listed.

## The claim

> **exp159's wall does not survive the swap. It still refuses every read of bank
> 8 — and the key is readable by Non-secure code anyway, because producing one
> ML-DSA-65 signature leaves copies of the seed in ordinary, open SRAM that no
> ACCESSCTRL register covers.**

Measured on a Pico 2 on 2026-08-21: **two copies**, the first at `0x20051cc0`,
read back by a demoted core 1 while bank 8 was shut, and they are byte-for-byte
the private key.

---

## The three numbers, against exp159

| | exp159 (P-256) | exp160 (ML-DSA-65) | |
| --- | --- | --- | --- |
| `.text` for the signing code | 20,356 | **16,380** | ← the post-quantum one is **smaller** |
| signature | 64 bytes | 3,309 bytes | 52× |
| public key | 64 bytes | 1,952 bytes | 30× |
| private key at rest | 32 bytes | **32 bytes** | the same — ML-DSA's key *is* a seed |
| the signing-key object in memory | 104 bytes | **65,696 bytes** | 632×, and 160 bytes larger than the biggest bank `ACCESSCTRL` can gate |
| stack frame of one signing call | 1,900 bytes | 188,116 bytes | 99×, both read off the prologue of the same scratch build |
| stack a signature actually reaches | not measured | **369,456 bytes** | measured on the board by painting and finding the low-water mark: 73% of this chip's usable RAM |
| one signature | 61 ms | 74–306 ms over nine runs | ← the spread is itself a finding, see below |
| the whole proof, in log lines | 5 | **173** | |
| whole firmware, UF2 | 93,184 | 91,136 | |

Both `.text` figures, and both stack-frame figures, come from the same method:
the two crates' signing paths built into an otherwise identical scratch firmware
and differenced against an empty baseline. It is the comparison exp159 set up in
advance so this experiment would have something to be measured against. The
`369,456` is the only figure here that needed a board, and it is 96% larger than
the prologue alone predicts — which is why it needed one.

**So the road's expected answer was the wrong way round.** Nobody needed to
worry about the code. What the swap costs is RAM, and the RAM is the reason the
wall fails.

---

## How this was designed, in the order it happened

### 1. Establish the facts before offering any option

Six, on 2026-08-21, all measured or read, none assumed. **Four changed the
design**, and two of them changed what the experiment is *about*.

| fact | how | what it changed |
| --- | --- | --- |
| `ml-dsa` 0.1.1 (RustCrypto) builds `no_std` for `thumbv8m.main-none-eabihf` on **stable** | compiled it | viable, and no nightly |
| ML-DSA-65 costs **16,380 bytes of `.text`** against P-256's **20,356** on the same baseline | built both | ← the road's premise was wrong, and the experiment had to be aimed somewhere else |
| the private key **is a 32-byte seed**, and `sign_deterministic` needs no RNG at all | read `signing.rs`, ran it | the seed fits bank 8 with 4,064 bytes to spare — so the obvious design *looks* fine |
| `SigningKey<MlDsa65>` is **65,696 bytes** in memory | `size_of` | ← **160 bytes larger than one 64 KB SRAM bank.** There is no single thing on this chip that ACCESSCTRL could wrap around it |
| after the `SigningKey` is dropped, **copies of the seed are still in the dead stack frame** | wrote it on a host, signed, then swept the frame it had just left | ← candidate 5 exists, and it is a measurement rather than a hunch |
| python-`cryptography` 50 verifies a raw ML-DSA-65 key and signature from this crate, and rejects a flipped bit | ran it | exp159's off-board method carries over — at `cryptography >= 46` |

The fifth one is the one worth stopping on. It was established **on a host, with
no board**, before a line of firmware existed — which is
[`the-board-is-the-loop`](../../docs/the-board-is-the-loop.md)'s lever 4 doing
exactly what it is for. Had it come back the other way, candidate 5 would never
have been written.

### 2. Ask what has already been answered

exp159 had already answered where a key goes (bank 8), why the gateway is a
mailbox and not the SIO FIFO, why core 1 parks instead of rebooting, and that
`ACCESSCTRL` writes need `0xACCE` in bits 31:16. None of it was re-derived. The
matrix, the breadcrumb harness and four of the five candidates are exp159's, and
the diff that matters is one dependency line and one new candidate.

### 3. Name the contradictions

#### C1 · exp159's wall holds 4 KB. This secret's working form is 65,696 bytes.

`ACCESSCTRL` gates ten SRAM banks: eight of 64 KB and two of 4 KB. So the
**finest** granularity is 4 KB and the **coarsest single unit** is 64 KB. An
ML-DSA-65 signing key, in the expanded form the arithmetic actually needs, is
65,696 bytes.

**It misses by 160 bytes.** There is no bank on this part that could hold one.

The 32-byte seed fits bank 8 easily, and that is what this firmware does. What
bank 8 cannot hold is what the seed turns into the moment it is used.

#### C2 · The naive port passes the matrix, and the pass is hollow

This is the third time this road has met the same defect, and the first time it
arrived from inside a dependency.

Candidate 4 — *bank 8 shut, Non-secure asks, 3,309 bytes come back* — **passes**.
On the board, cleanly, first time. An experiment that stopped there would have
reported a success, and it would have been the same kind of success the prior
work this road was filed against reported.

Because while that was happening, the signing ran on core 0's ordinary stack, in
the main 512 KB, which **defaults to fully open access** and is the same region
core 1's own stack is in.

> exp159's idea to take away was *a boundary is only as good as the worst place
> the secret lives*, and it was written about flash — somewhere the author might
> put a key. Here the worst place is not somewhere anybody put it. **It is
> somewhere the library put it**, for a few milliseconds, and never cleaned up.

So candidate 5 goes looking. And the sweep is an observation rather than a
coincidence because the region is **painted with `0xC5` before the signature is
made**: anything found afterwards was put there by this signature and by nothing
else. `check.sh` asserts the paint is there, because without it a hit proves
nothing.

#### C3 · A 3,309-byte signature does not fit the way this repository reports

`usb-log` truncates at 96 bytes per line and drops the newest line when its
16-deep queue fills — exp156 lost its headline finding to the first and three
findings to the second. exp159's entire proof was five lines.

exp160's is **173**, emitted 32 bytes at a time, each line carrying its own index
so a reader can tell a missing chunk from a short capture, and paced at 5 ms so
the queue never overflows. `verify.py` reassembles them and refuses to report
anything if one index is absent.

That is not a workaround. It is one of the costs the road was asking about, and
it is the one that shows up in every part of a system a signature has to travel
through.

### 4. Write it as a matrix, so one flash answers everything

```text
  1  Secure core 0 makes one ML-DSA-65 signature        it fits at all  (control)
  2  Non-secure core 1 reads bank 8, ALLOWED            must work       (control)
  3  Non-secure core 1 reads bank 8, DENIED             must be refused
  4  Non-secure asks for a signature, bank 8 shut       3,309 bytes back
  5  Secure sweeps the stack it just signed on,
     and Non-secure reads what it finds                 ← the finding
```

One candidate per boot, five boots, one flash, about a minute.

**Candidate 1 is a control in a way exp159's was not.** 369 KB of stack is most
of this chip, so *does one signature fit alongside the harness at all* is a real
question with a real chance of "no" — and if the answer had been no, the
breadcrumb would have named the candidate instead of leaving a dark board.

Candidates 2 and 3 are exp159's pair, unchanged, and they are what makes
candidate 5 mean something: the wall is **demonstrably still standing** at the
moment the key is read out of somewhere else.

---

## The result

All five candidates behaved as expected — and for candidate 5, "as expected" is
the bad news. `check.sh` says so in those words rather than reporting a plain
pass, because a check that reports this as a success has learned nothing from
exp159.

**One ML-DSA-65 signature reached 369,456 bytes down the stack**, out of 503,428
available. The first attempt at measuring this painted 320 KB — chosen from the
`sign_once` prologue's 188,116-byte frame — and came back **saturated**, which is
how it was discovered that the call goes more than 139 KB past its own frame in
the functions it calls. The instrument now says `SATURATED, not a depth` when it
hits its own limit, because a saturated measurement quoted as a result is a
number that means the opposite of what it looks like.

**Signing time varies by 4.1× across nine measurements on the board** — 74, 74,
79, 79, 97, 231, 254, 288 and 306 ms. That is not noise and it is not the flash cache: ML-DSA's
signing loop is rejection-sampled, so the number of attempts depends on the
message. Three hundred signatures with one key on a host spread **21.5× between
fastest and slowest**, which is where the mechanism was confirmed without
spending a bench trip on it. Against P-256's fixed 61 ms this is a different
shape of cost, and anything with a timeout in it needs the tail rather than the
median.

**Bank 8 survived every watchdog reset**, as it did for exp159 — the same seed
came back on boots 2 through 5. It did **not** survive `yi26 bootsel` followed by
a PICOBOOT reflash: boot 1 of the next run generated a fresh seed. That is a
different kind of reset and it runs the bootrom's own code, which uses SRAM.

## How to see it

```sh
./check.sh                       # exit 0; it asserts the matrix and verifies the signature
yi26 log --seconds 60            # the settled report, repeating every five seconds
python3 ./verify.py < capture.txt # verify the recorded run by hand, no board needed
```

The run takes about a minute and the port disappears four times, so `yi26 log`
returns fragments until it settles.

LED: **slow** while the matrix is being walked, **fast** once it is done.

## Expected output

Pasted from a real run on a Pico 2, Ubuntu, 2026-08-21, flashed with
`yi26 pflash` and read across the board's own reboots. Trimmed for length;
nothing is edited. The full 173-line report block is checked in as
[`capture.txt`](./capture.txt).

```console
[    3039 ms] exp160 up, boot #1. The matrix so far:
[    3039 ms]   1 Secure signs with the seed in bank 8 - not reached
[    3039 ms]   2 Non-secure reads bank 8, allowed - not reached
[    3039 ms]   3 Non-secure reads bank 8, DENIED - not reached
[    3039 ms]   4 Non-secure asks for a signature - not reached
[    3039 ms]   5 Non-secure reads the copy on the stack - not reached
[    3039 ms] new ML-DSA-65 seed from the TRNG, written to bank 8 and nowhere else.
[    3039 ms] stack: sp near 0x2007fb04, floor 0x20004c80, 503428 bytes of room
[    8039 ms] candidate 1 Secure signs with the seed in bank 8
[    8114 ms]   one ML-DSA-65 signature in 74 ms, 3309 bytes.
[    8114 ms] PKHD 70c2763b8b2fecc5b80790fd67992ce5aa7424b029baa24082ab75c34920270d
[    8114 ms] SGHD 692c7aaca1d1f49c325ccd1259a5fc8a390dd1a4aafffeaa4048ef3dd52831ed
[    8114 ms] candidate 1 -> as expected

[    3074 ms] bank 8 still holds this run's seed: it survived the reboot.
[    8074 ms] candidate 2 Non-secure reads bank 8, allowed
[    8074 ms]   bank 8 to Non-secure: OPEN
[    9085 ms]   core 1: done=true faulted=false read=0x4b455932
[    9085 ms] candidate 2 -> as expected

[    8074 ms] candidate 3 Non-secure reads bank 8, DENIED
[    8074 ms]   bank 8 to Non-secure: SHUT
[    9085 ms]   core 1: done=false faulted=true read=0x00000000
[    9085 ms] candidate 3 -> as expected

[    8074 ms] candidate 4 Non-secure asks for a signature
[    8074 ms]   bank 8 SHUT, and it stays shut while the seed is used.
[    8079 ms] MSG  69e7cc54556db35ad4cab4386c3696b4b26cde56c698a9578a1b5357b349b342
[    8099 ms]   Non-secure asked for a signature: true
[    8353 ms]   Secure signed it in 254 ms, 3309 bytes into the mailbox.
[    8853 ms]   Non-secure read it back: 0xd653d65f (want 0xd653d65f)
[    8853 ms] candidate 4 -> as expected

[    8074 ms] candidate 5 Non-secure reads the copy on the stack
[    8074 ms]   bank 8 SHUT for this whole candidate.
[    8096 ms]   painted 471040 bytes of stack below 0x2007fac4 with 0xc5.
[    8194 ms]   signed in 97 ms; the stack went down to 0x20025794, 369456 bytes deep.
[    8354 ms]   copies of the 32-byte seed left in open SRAM: 2
[    8354 ms]   first copy at 0x20051cc0, outside bank 8, in the main 512 KB.
[    8364 ms]   core 1 read 32 bytes from there: done=true faulted=false
[    8364 ms]   they are the key: MATCH
[    8364 ms]   GRAB 526a35b68c8733ab... (8 of 32; the board compared all of them)
[    8364 ms] candidate 5 -> as expected

[   13246 ms] exp160 done after 5 boots. Nothing armed; still reflashable.
[   13246 ms]   1 Secure signs with the seed in bank 8 - as expected
[   13246 ms]   2 Non-secure reads bank 8, allowed - as expected
[   13246 ms]   3 Non-secure reads bank 8, DENIED - as expected
[   13246 ms]   4 Non-secure asks for a signature - as expected
[   13246 ms]   5 Non-secure reads the copy on the stack - as expected
[   13246 ms] KATP 424b2f267e58d5b3b44d71acfc6a656bb26950d57c61db1c880bcfa1feab443f
[   13246 ms] MSG  c9b4526499ec555649d59a310e54ca8c7116650e0f6753db0ee38751c9cc9839
[   13246 ms] PK000 70c2763b8b2fecc5b80790fd67992ce5aa7424b029baa24082ab75c34920270d
...                                                        (61 PK lines in all)
[   13548 ms] PK060 3e8147d13a0cd2a420001a4f185a4472cb40000796de8b3cb00d0c9a56b4fd1b
[   13553 ms] SG000 bdbad2bfd9a2e6633f9724dceca1596775586004d6305ed42285c2ccdfbb48cd
...                                                       (104 SG lines in all)
[   14073 ms] SG103 00000000000000080d141a242d
```

`./check.sh` on the same board:

```console
PASS  toolchain present (cargo, elf2flash)
PASS  firmware compiles (162576 byte ELF)
PASS  converts to UF2 (91648 bytes)
PASS  UF2 family ID is e48bff59 (rp2350-arm-s)
PASS  no private key is compiled into the firmware
PASS  the known-answer seed is all zeros, and published
PASS  the known-answer seed never signs and never reaches bank 8
PASS  the signing seed comes from the hardware TRNG at runtime
PASS  the firmware never writes ACCESSCTRL.LOCK
PASS  the sweep region is painted before the signature is made
PASS  the firmware never logs a whole private key
PASS  the product string is bounded at build time
PASS  the LED heartbeat starts before the USB stack
PASS  the run has a hard stop that disarms
PASS  verify.py replays the recorded capture
PASS  the corrupted-capture test actually corrupts something
PASS  verify.py rejects a capture with one corrupted byte
PASS  board enumerated as 1209:0001
PASS  every candidate was attempted
PASS  every candidate behaved as expected
PASS  control: one ML-DSA-65 signature fits on this chip at all
PASS  control: Non-secure read bank 8 while it was OPEN
PASS  the wall: Non-secure was refused once bank 8 was SHUT
PASS  Non-secure got 3,309 bytes back with bank 8 still SHUT
PASS  THE FINDING: Non-secure read the private key out of open SRAM, wall intact
PASS  the board's ML-DSA-65 key generation matches OpenSSL (no library needed)
PASS  the signature verifies off the board, and the check can fail
```

Three of those lines need `cryptography >= 46`; on an older one they report
`SKIP` and name the `pip install` that fixes it, and the run still passes.
**The known-answer line needs nothing at all** — see below.

## Two verifications, because they fail differently

The road said *"let something else check them"*, and exp159 established why: a
signature checked by its own signer proves the two **agree**, and a shared bug in
encoding, endianness or hashing cancels out perfectly.

exp160 has two of those checks, and neither replaces the other.

**The known-answer test needs no library, no network and no toolchain.**
FIPS-204 key generation is deterministic, so the public key for the all-zero seed
has exactly one correct value. OpenSSL and RustCrypto's `ml-dsa` were made to
agree on it on a host before any of this was flashed, and it starts
`424b2f26…`. The board prints its own answer as `KATP` and `check.sh` compares
it with `grep`. If the board's arithmetic is wrong, nothing else here means
anything, and that is worth knowing on a machine with nothing installed.

The seed is all zeros, it is **published**, it never enters bank 8 and it never
signs anything. `check.sh` asserts all three, because a known-answer seed is a
key literal wearing a label unless somebody checks.

**The signature is verified by a different implementation.** `verify.py` uses
`cryptography` — OpenSSL underneath, a different language, a different machine —
and it then flips one bit of the challenge and **requires the verification to
fail** before it reports that it passed.
[exp140](../exp140-a-checksum-that-passes/) is what this repository calls a check
that cannot fail.

`verify.py` was replayed against a synthetic 173-line block in exactly the
board's format **before the board was ever flashed**, which is where the
chunk-index handling was fixed. It is now replayed against a real capture by
`check.sh` on every run, including a deliberately corrupted copy, so nobody
spends a bench trip discovering that the parser has never seen real output.

## What is not verified here

- **This is not secure boot, and it is not a secure element.** The seed is in
  volatile SRAM; it dies at power-off and it is regenerated on the next reflash.
  Nothing here provisions, attests, or persists an identity.
- **No remedy is attempted, and its price is not measured.** Nothing wipes the
  stack after signing. Whether wiping 369 KB is affordable, and whether wiping
  the frame is even sufficient — registers, the executor's own buffers, whatever
  the DMA engine touched — is the obvious next question and none of it is asked
  here.
- **Two copies of the seed were found. That is not "the leak is two copies."**
  The sweep looks for the 32-byte seed and nothing else. Expanded key material,
  intermediate polynomials and the signing nonce are all secret too, and none of
  them has a fixed pattern to grep for, so the count is a lower bound on a
  question this experiment did not ask.
- **Whether SRAM banks 0–7 are striped across the main address range is still
  unmeasured, and it now matters.** exp159 said the question stops mattering
  because bank 8 is separate. A secret larger than 64 KB has no bank to live in,
  so hiding one would mean denying *several* banks to Non-secure code — and that
  is only possible if the address range maps to banks in a way somebody has
  checked. It has not been checked here.
- **Only reads were tested against the wall.** Nothing tries a Non-secure
  *write* to bank 8, a DMA transfer, or the debugger. `ACCESSCTRL` has bits for
  DMA and DBG and none of them were exercised.
- **`ACCESSCTRL.LOCK` is deliberately never written**, so every configuration
  here is one power cycle from ordinary — which also means none of it survives a
  reset on its own.
- **The mailbox is not hardened.** Non-secure can ask for a signature over
  anything, as often as it likes.
- **Timing is now known to vary, and is still not characterised.** Four board
  measurements and 300 host ones say the spread is real and large. Nobody has
  established whether it is exploitable on this part, and a rejection-sampled
  signature is exactly the shape where that question is not rhetorical.
- **The A/B slot question is answered about the signer, not the verifier.**
  [exp147](../exp147-two-firmwares-one-phone/) needs a firmware to fit a 64 KiB
  slot, and what would go in that slot is code that *verifies*, which is a
  different and much smaller thing than the 16,380 bytes measured here. It is not
  built.
- **One board, one part, one afternoon.** Everything above is Ubuntu against one
  Pico 2.

## The ideas to take away

1. **Ask where the secret is while it is being used, not only where it is
   kept.** exp159 asked where else the key exists and found flash. exp160 asked
   the same question one layer down and found the stack — put there by a
   dependency, in a region no register covers, and left there afterwards. *A
   boundary drawn around storage says nothing about computation.*

2. **The granularity of your protection is a hard limit on what you can
   protect.** 65,696 bytes against a 65,536-byte bank is not a tuning problem. A
   mechanism that gates memory in fixed blocks cannot hide something bigger than
   one block, and it is worth finding that number out **before** choosing the
   algorithm rather than after building the wall.

3. **The experiment whose finding is a leaked key must not be the thing that
   publishes it.** The first version printed all thirty-two bytes core 1 had
   grabbed, so that a reader could see the two sides agree. Those bytes are the
   private key, and this log gets pasted into a README and rendered by a web
   page — which would have put a working private key next to its own public key
   in a public repository. It prints eight now, and the comparison over all
   thirty-two happens on the board where it belongs. `check.sh` greps for the
   pattern that would bring it back.

4. **A measurement that hits its own limit must say so.** The first sweep
   reported "327,680 bytes deep" and that was exactly the size of the region
   swept — a saturated instrument reading back its own ceiling. It looked like a
   result. The fix is one `if`, and the reason it was caught at all is that the
   number was suspiciously round.

5. **A check that corrupts nothing is a check that cannot fail — and it happened
   here, in the code written to prevent it.** `check.sh` proves `verify.py` can
   fail by corrupting one hex digit of the recorded capture and requiring a
   rejection. The first version wrote `f` over that digit. In the capture that
   got checked in, the digit was **already `f`**, so it corrupted nothing,
   `verify.py` correctly said `OK`, and the guard read as a pass. It was only
   caught because the run that finally had a new enough `cryptography` reached
   that line for the first time. The corruption now rotates the digit, and a
   separate assertion checks that the file actually changed. *The check on the
   check is not paranoia; it is the same rule applied one level up.*

6. **The expensive fact was free.** That signing leaves the seed on the stack was
   established on a laptop, in about a minute, before any firmware existed. Every
   design decision below it depended on that answer, and getting it wrong would
   have cost a bench trip and produced an experiment with nothing to find.

## Next

**The remedy, and what it costs.** Everything above is a defect report. The
open questions it leaves are one experiment: wipe the working region after
signing and measure the price in milliseconds; find out whether wiping the frame
is enough or whether secret material survives somewhere the sweep does not
reach; and settle whether banks 0–7 map to the address range in a way that would
let a >64 KB secret region exist at all. **If the answer to the last one is no,
then this chip cannot hide an ML-DSA private key in use**, and that is a finding
the road should record before anything is built on the assumption that it can.
