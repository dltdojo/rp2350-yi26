# exp166 — whose firmware will it accept

The [signing road](../README.md#the-signing-road) opens with the sentence that
names it:

> The update road answered **can an update brick this board**. It said at the
> outset that ***whose firmware will it accept*** was a separate group, and this
> is it.

Eight experiments later, **no board in this repository had ever checked a
signature.** [exp159](../exp159-a-key-that-was-never-in-flash/) and
[exp160](../exp160-a-secret-too-big-to-hide/) both *produce* signatures and send
them to a host to be verified, which is the right control for an experiment
about signing and leaves the road's own question untouched.

This is that question. **A board accepts a P-256 signature over a region of its
own flash chosen at random after the firmware was built, and refuses four
different ways of getting it wrong** — including the one most verifiers get
wrong.

## Signing needs a secret. Verifying needs only integrity.

The road spent six experiments finding out whether this chip can keep a private
key. It can't, in use, and [exp162](../exp162-how-wide-can-a-wall-be/) and
[exp163](../exp163-how-long-is-a-secret-in-the-open/) are exactly how far it
gets. None of that applies here:

| | signing (exp159–exp165 went here) | verifying (this) |
|---|---|---|
| needs | a **private** key hidden from the board's own code | a **public** key everyone may read |
| the attack | read the key out | **swap** the key |
| exp162's four-byte granularity | applies | does not apply |
| exp163's 63% rebuild cost | applies | does not apply |
| needs TrustZone | to hide, yes | **no** |

So this sits back at the [update road](../README.md#the-update-road)'s
difficulty rather than at the Armv8-M step
[the road's difficulty note](../README.md#the-signing-road) warns about. It uses
no SAU, no `ACCESSCTRL`, and no second core.

## The ceiling, stated first rather than discovered

**The public key this firmware trusts is 65 bytes of ordinary flash, and
anybody who can write flash can replace it.** That is not softened anywhere in
this experiment, and it is measured twice:

- the firmware reads `ACCESSCTRL.XIP_MAIN` on every boot and prints it —
  `0x000000ff`, open to every master, which is exp159's finding re-taken rather
  than quoted;
- `check.sh` **finds the key inside the built `.uf2` by byte search** and prints
  the offset, so "somebody could change which firmware this board accepts" is
  demonstrated on this repository's own output.

```console
PASS  the trusted key is 65 plain bytes in the .uf2, at flash offset 0xaf04 of 45824 — anybody with the file can change it
```

That is [exp140](../exp140-a-checksum-that-passes/)'s lesson one layer up.
exp140 forged a CRC to any value with four bytes and showed the same attack
failing on a hash; here the gap is not between reliability and authenticity but
between **checking a signature** and **being unable to not check it**. The first
is built below. The second needs a fuse this road does not burn, and saying so
is the point rather than a disclaimer.

## The bar, and it is exp159's pointed the other way

exp159's finding was that the board signed a challenge **it could not have known
at build time**. The mirror is the only honest bar for a verifier.

So the host picks a **random offset and length** into the board's own flash for
each run — seeded from the clock in `check.sh` — signs the bytes that live
there, and sends the 64-byte signature. The firmware carries the public key and
nothing else: no digest, no signature, no region, no seed.

## The digest is what makes the verdict checkable

A verifier that reports only pass or fail can be trusted and cannot be checked.
So the board **prints the SHA-256 of the region it read, before it prints its
verdict and whether or not the answer is yes**, and the host prints its own
SHA-256 of the same named bytes. `verify.py` requires the two to be equal.

```
>>> host: mode=good expect=ACCEPTED named=0x269e+11635 sha256=0db2af7d...
[    9996 ms]   region: offset=0x269e len=11635 (0x1000269e..0x10005411)
[   10141 ms]   sha256 = 0db2af7df8e173f5b03e5fa836720e9b81c7e54d2aff3b0c4e594f54a6098f8f
```

Without it, a board that hashed the wrong bytes and refused everything would
look exactly like a board doing its job.

## Framing, and the one place a missing checksum costs nothing

A signature is 64 bytes and a CDC packet is 64 bytes, so a request never fits in
one and the boundary has to come from the bytes. The road already decided that:
[exp136](../exp136-joining-halfway/) measured that length-prefix resynchronises
by luck and **invents three frames** where COBS invents none, and wrote down
why it matters here specifically —

> an invented frame carrying a signature is a signature-shaped thing that fails
> to verify, and a reader will blame the cryptography for what the framing did.

So [`framing`](../../crates/framing/)'s COBS, which says of itself:

> It has no checksum, no version byte, and no opinion about what a payload
> means — and a frame layer without a checksum cannot tell a corrupted payload
> from a real one.

**Here it does not need one.** A corrupted payload is a signature that does not
verify, and that is the outcome this firmware exists to produce. It is the one
place on either road where that missing checksum costs nothing.

Two details that are not decoration:

- the decoder is **`joined`, not `fresh`**. This board can never know it is
  reading a host's stream from its first byte — the port may have been opened
  and closed, and the firmware outlives every such session. A `joined` decoder
  refuses to emit what it assembled before the first delimiter, so a fragment
  cannot become a 73-byte frame by accident. Senders lead with a delimiter,
  which costs one byte and shows up as `1 discarded` on every request.
- **a zero-length frame is not a message.** That leading delimiter closes an
  empty frame behind the previous one once the decoder is synchronised, and the
  first run of this experiment counted to eleven for five requests before that
  was noticed. exp118 wrote the same rule down about a zero-length USB *packet*;
  it is true one layer up and had to be learned again.

## The six requests

`sign.py` builds each one, and every mode exists because it can come out the
other way.

| mode | what it changes | why it is here |
|---|---|---|
| `good` | nothing | the check can pass at all |
| `flip-sig` | one bit of the signature | the signature is actually examined |
| `wrong-key` | signed by a second test key | **which** key is examined |
| `wrong-region` | a **valid** signature by the trusted key, over a *different* region than the frame names | the signature is bound to **these bytes** |
| `truncated` | the frame cut to 53 bytes | a malformed request is refused, not read past |
| `good` again | nothing | the board survived every refusal |

**`wrong-region` is the one worth arguing about.** A verifier that asks *"is
this a signature by the key I trust?"* passes it; only one that asks *"is this a
signature by the key I trust **over the bytes this request names**?"* refuses.
Nothing else in this matrix catches the difference, and an implementation can be
wrong about it while passing every other test here.

The final `good` is the control exp163 would have wanted: a verifier that stops
working after it says no once can be switched off by being lied to.

## The result

One run on a Pico 2, 2026-08-22. Six requests, six correct answers.

```
  ACCEPTED: signed by the key this board trusts
  REFUSED (cryptography): the signature is not this key's, over these bytes
  REFUSED (cryptography): the signature is not this key's, over these bytes
  REFUSED (cryptography): the signature is not this key's, over these bytes
  REFUSED (plumbing): the frame is 53 bytes, not 73
  ACCEPTED: signed by the key this board trusts
```

Every refusal names **which layer** said no, because a reader who cannot tell
plumbing from cryptography blames the wrong one — exp136's whole concern,
arriving as a logging requirement.

### Verifying is slower than signing, and that surprises people

```
  hashed in 6404 us, verified in 97705 us
```

| | on this part |
|---|---|
| SHA-256 over 11,635 bytes of XIP flash | **6.4 ms** |
| one P-256 verification | **97.7 ms** |
| one P-256 signature ([exp159](../exp159-a-key-that-was-never-in-flash/)) | **61 ms** |

**Verification costs 1.6× what signing costs here.** It is the right way round
for ECDSA — verifying does two scalar multiplications where signing does one —
and it is the opposite of the intuition that the side without a secret must be
the cheap side. An update path that verifies on the board pays this once per
image, and the hash is a rounding error next to it.

The digest cost also says something about scale: 6.4 ms for 11.6 KB is about
1.8 MB/s, so hashing a whole 64 KB image would cost about 36 ms — still less
than half of one verification.

## What it cost to find out

Three flashes, and both mistakes were in the instrument rather than in the
board — the pattern [exp164](../exp164-the-wall-nobody-read/) named.

- **The log counted to eleven for five requests.** The leading delimiter that a
  `joined` decoder needs closes an empty frame behind the previous one once the
  decoder is synchronised, so every request arrived as two: one empty, one real.
  Nothing about the verdicts was wrong; the numbering was, and a totals line
  that describes twice as much work as happened is a line a reader will use.
  exp118 had already written this rule down about a zero-length USB *packet*.
- **`verify.py` compared the board's request counter against the length of the
  transcript**, which is right for a fresh capture and wrong the moment
  `check.sh` drives a board that has already answered something — the counter is
  cumulative since boot. It failed correctly, about the wrong thing. It now
  requires the counter to advance by **exactly one per exchange**, which holds
  in both cases and catches more: a request counted twice, or one lost between
  two lines of the same log.

One thing that is not a mistake and is worth writing down: **opening and closing
the CDC port six times in a row loses a frame about once in twenty-four
requests.** The board's own counter says which — a frame it never received is
one it never counted — so a lost frame is distinguishable from a board that
ignored a request, and it is not a verification result. `check.sh` retries once
and **prints a `NOTE` when it does**, because a check that hides a flake reports
a link as steadier than it is. [exp119](../exp119-cancelled-reads/) and
[exp136](../exp136-joining-halfway/) are what this loop is made of.

## What this does not do

**It does not install anything.** `ACCEPTED` is a verdict printed, not a slot
marked bootable. Joining the verdict to the ROM's `explicit_buy` machinery that
[exp143](../exp143-the-image-that-is-never-bought/) measured is the next
experiment, and `check.sh` fails if this firmware acquires the ability to write
flash — a board that could install while proving it refuses is a worse witness
to the refusal.

## What is not verified here

- **The trust is not enforceable.** See the ceiling above. This board checks a
  signature; nothing stops somebody making it check a different key's, and
  closing that needs OTP that this road does not burn.
- **The region is inside the running image.** The host can only predict flash
  it put there, so a region beyond the image would be signing bytes nobody can
  reproduce. Nothing here verifies an image the board is *about to* install.
- **One curve, one hash.** P-256 and SHA-256. The post-quantum half — and
  whether ML-DSA verification is as lopsided the other way — is unmeasured.
  exp160 found ML-DSA's *signing* code smaller than P-256's, so the guess is
  worth nothing without a measurement.
- **The private keys here are test keys, published in this README**, and are
  never on the board. Nothing signed by them means anything.
- **No timing claim is made about the verification itself.** The 97.7 ms is a
  cost, not a constant-time guarantee, and a verifier is public-input code
  anyway.
- **`yi26 send` is the only sender tested.** A phone has not tried this;
  whether a browser's WebCrypto can produce a signature this board accepts is
  the road's own open question and is not answered here.

## The test keys

Both are published on purpose, both are worthless, and neither is on the board.

```
trusted (the firmware carries the public half)
  private  a7c08e6335cc688ced091da7f381971aee587d3783f9924233d85e488a034fe0
  public   0461788817a141903fb9ac46ab03fbde47181262ad410b690988a0b9d167cecd
           eeed2d1f96defb9c8443fe1d569ef559a6c4bacb8c359a10579b120a63f09aad
           b0

"somebody else" (used only by the wrong-key request)
  private  a03a8c8cd7659136f840ea68ae7005c25c5a84d3a236efd557ecf4eb6086f174
```

## Running it

```console
cd experiments/exp166-whose-firmware-will-it-accept
cargo build --release
elf2flash convert -b rp2350 \
  target/thumbv8m.main-none-eabihf/release/exp166-whose-firmware-will-it-accept \
  target/exp166.uf2
yi26 bootsel && yi26 pflash target/exp166.uf2
./check.sh                     # builds, signs, sends and grades all six
```

One request by hand:

```console
python3 sign.py target/exp166.uf2 good 42 | python3 -c \
  'import json,sys; print(json.load(sys.stdin)["escaped"])' | xargs yi26 send
```

`sign.py` prints JSON: the escaped wire bytes, the region it named, and **the
SHA-256 it computed**, which is the number to compare with the board's.

To check a transcript you already have, on any machine, with a Python that has
`cryptography` — or without it, since `verify.py` needs no crypto at all:

```console
python3 verify.py < capture.txt
```

`verify.py` never trusts either voice about the other. It requires the board's
digest to equal the host's, the board's region to equal the region the host
named, each verdict to match what the host expected, refusals to come from the
right layer, at least one of each verdict to appear, the last request to be
accepted, and the running totals to add up. A transcript that starts mid-run —
which is what driving the board from a shell produces — is checked just as hard
on everything it contains.

## Expected output

Pasted from a real run on a Pico 2, Ubuntu, 2026-08-22. The full transcript,
both voices, is checked in as [`capture.txt`](./capture.txt).

```console
[    3117 ms]   trusted key lives at 0x1000af04, 65 bytes
[    3237 ms]   ACCESSCTRL.XIP_MAIN = 0x000000ff
[    3278 ms]   the key is in flash that register leaves open to every master - anybody who can
[    3318 ms]   write flash can choose whose firmware this board accepts.
[    3358 ms]   This check can be flashed over. Closing that needs a fuse.
[    3398 ms] listening.

>>> host: mode=good expect=ACCEPTED named=0x269e+11635 sha256=0db2af7d...
[    9956 ms] --- request #1: 73 byte frame, 1 discarded
[    9996 ms]   region: offset=0x269e len=11635 (0x1000269e..0x10005411)
[   10141 ms]   sha256 = 0db2af7df8e173f5b03e5fa836720e9b81c7e54d2aff3b0c4e594f54a6098f8f
[   10181 ms]   hashed in 6404 us, verified in 97705 us
[   10221 ms]   ACCEPTED: signed by the key this board trusts

>>> host: mode=wrong-region expect=REFUSED named=0x5351+13961 sha256=5af14fa8...
[   19664 ms]   region: offset=0x5351 len=13961 (0x10005351..0x100089da)
[   19810 ms]   sha256 = 5af14fa8200f4b7703caa0e02c943e0f0fef2d2f7007475fa719986628671f22
[   19850 ms]   hashed in 7527 us, verified in 98387 us
[   19890 ms]   REFUSED (cryptography): the signature is not this key's, over these bytes

>>> host: mode=truncated expect=REFUSED named=0x269e+11635 sha256=0db2af7d...
[   22845 ms] --- request #5: 53 byte frame, 1 discarded
[   22925 ms]   REFUSED (plumbing): the frame is 53 bytes, not 73
[   26419 ms]   totals: 6 asked, 2 accepted, 3 refused, 1 malformed
```

`./check.sh` on the same board:

```console
PASS  no private key is on the board
PASS  the trusted key is a 65-byte SEC1 public point (leading 0x04)
PASS  the firmware never writes flash or OTP (ACCEPT is a verdict, not an install)
PASS  the region is bounds-checked before the slice exists
PASS  there is exactly one raw slice in the firmware
PASS  the COBS decoder is joined, not fresh: the board is always a late joiner
PASS  zero-length frames are skipped, not counted (exp118's rule, one layer up)
PASS  the digest is printed before the verdict, so a refusal still carries it
PASS  the trusted key is 65 plain bytes in the .uf2, at flash offset 0xaf04 of 45824 — anybody with the file can change it
PASS  verify.py rejects a board digest that is not the host's (got DISAGREE)
PASS  verify.py rejects a verdict the host did not expect (got DISAGREE)
PASS  verify.py rejects a truncated frame refused by the wrong layer (got DISAGREE)
PASS  verify.py rejects a request counter that skips (got DISAGREE)
PASS  the board answered all six requests
PASS  a correctly signed request is accepted
PASS  a bad signature is refused by the cryptography
PASS  a truncated frame is refused by the plumbing, and the board keeps going
PASS  a valid signature over a different region is refused
PASS  every live verdict re-derives off the board, digests included
```

## Four things to take away

1. **A road can answer everything except its own question.** Six experiments
   went looking for a way to hide a private key, and the question on the tin
   needed a public one. The two are so close together that nobody noticed for
   eight experiments — including whoever was choosing what to build next.
2. **Secrecy and integrity are different problems and only one of them was
   hard here.** Every limit exp160 through exp165 found is real and none of it
   applies to a verifier. That is worth knowing *before* choosing a mechanism,
   not after measuring one.
3. **"Is this signed by my key" is not "is this signature over these bytes."**
   The `wrong-region` request is the whole difference, and an implementation can
   be wrong about it while passing every other test in this directory.
4. **A check you can rewrite is still worth building, and worth labelling.**
   This board really does refuse somebody else's firmware. It also cannot stop
   that somebody replacing the key — and the honest thing is to measure how
   easily, which is a byte search over the repository's own build output.

## Next

**The verdict has nowhere to go.** `ACCEPTED` is printed and then forgotten;
the update road already measured the machinery that would act on it —
[exp142](../exp142-two-images-one-version/)'s version comparison and
[exp143](../exp143-the-image-that-is-never-bought/)'s `explicit_buy`, where an
image the ROM will boot is one somebody deliberately bought. **Verify, then
buy** is the experiment that joins the two roads, and it is the first one here
that would write flash.

Two smaller things, both cheap:

- **can a phone verify what the board just handed it**, which is the road's own
  open question and now has a matching half to test against;
- **what ML-DSA verification costs**, since exp160 found its *signing* code
  smaller than P-256's and there is no reason to guess which way this goes.
