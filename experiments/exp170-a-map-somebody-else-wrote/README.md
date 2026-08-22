# exp170 — a map somebody else wrote

[exp169](../exp169-what-it-says-it-can-do/) wrote a CBOR map. This one **reads**
one, and the map comes from whoever is holding the other end of the cable.

Still no cryptography, still no credential, still no secret. The third
experiment on the [authenticator road](../README.md#the-authenticator-road),
and the last one before signing.

> **Verified on hardware, 2026-08-22.** Twenty cases, eight of them
> `authenticatorMakeCredential` requests. A well-formed one is read in full —
> `rp.id = "example.test"`, a four-byte user handle, a 32-byte client data hash,
> `alg = -7 (ES256)` — and then **refused with a status that means "understood
> and denied"** rather than "I do not know this command". Six malformed ones
> draw three other statuses, including a byte string whose length runs past the
> message. See [Expected output](#expected-output).

## Why this is its own experiment

`makeCredential` is six things: reading a request, generating a key, wrapping
it, building authenticator data, signing, and asking a person. The
interrogation for this rung said so and split it, because **one of those six is
the attack surface and deserves to be measured on its own.**

> **A CTAP2 authenticator parses bytes an attacker chose, and the lengths in
> CBOR are part of those bytes.** A reader that trusts a length reads past its
> buffer. That is the oldest bug in embedded parsing, and
> [exp140](../exp140-a-checksum-that-passes/)'s lesson — *a check that cannot
> fail has not passed* — applies to it exactly.

So this device reads the request, reports what it read, and refuses. Nothing it
reads can make it do anything, which is the only state in which a parser is
worth testing this hard.

## Three statuses, and the difference is the finding

exp169 answered `makeCredential` with `CTAP1_ERR_INVALID_COMMAND` — *I do not
know this command*. That was true then. It now has three answers, and which one
comes back says which layer said no:

| case | status | what it means |
|---|---|---|
| `mc-good` | `CTAP2_ERR_OPERATION_DENIED` (0x27) | **read in full, understood, refused anyway** |
| `mc-lying-length` | `CTAP2_ERR_INVALID_CBOR` (0x12) | a byte string whose length runs past the message |
| `mc-noncanonical` | `CTAP2_ERR_INVALID_CBOR` | a map header written wider than it needs to be |
| `mc-trailing` | `CTAP2_ERR_INVALID_CBOR` | a complete request with a byte after it |
| `mc-missing-cdh` | `CTAP2_ERR_MISSING_PARAMETER` (0x14) | no `clientDataHash` |
| `mc-missing-params` | `CTAP2_ERR_MISSING_PARAMETER` | no `pubKeyCredParams` |
| `mc-no-es256` | `CTAP2_ERR_UNSUPPORTED_ALGORITHM` (0x26) | RS256 only: understood, unusable here |
| `mc-many-algs` | `CTAP2_ERR_OPERATION_DENIED` | ten algorithms, more than this device records |

**`mc-good` is the one worth arguing about.** A device that refused everything
without reading it would produce the same status byte. So the board prints what
it parsed, and `verify.py` requires that report to be in the transcript: a run
in which nothing was ever reported as parsed is a run whose statuses could be
reflexes.

```
makeCredential, and it parsed:
  rp.id      = "example.test"
  user.id    = 4 bytes
  clientData = 0001020304050607 (32 bytes)
  alg        = -7  (ES256)
ES256 was offered, and this device still has no key to sign with.
refusing with 0x27, having understood the request.
```

## The reader, and the one line the whole thing rests on

[`crates/cbor`](../../crates/cbor/) gained a `Reader` to go with exp169's
`Writer`. It is bounds-checked, canonical-only, allocation-free, and it borrows
rather than copies — a parser that copies every field an attacker sends is a
parser an attacker sizes.

Every length goes through one function:

```rust
let end = self.at.checked_add(n).ok_or(ReadError::Truncated)?;
if end > self.buf.len() {
    return Err(ReadError::Truncated);
}
```

`checked_add` because `at + n` on a length from the wire is where an overflow
turns a refusal into a read. `check.sh` counts the places the reader indexes its
buffer and fails if there is more than one — **a second, unchecked path is a
hole**, and one is the number that can be read at a glance.

Eleven of the crate's twenty tests are about input nobody well-behaved sends:

```
a length longer than the buffer      Truncated     58c8010203, 5b7fffffffffffffff
a header cut in half                 Truncated     58, 19ff, (empty)
23 written in two bytes              NotCanonical  1817
an indefinite length                 NotCanonical  9f, bf, 5f
an array of three holding two        Truncated     830102
six nested arrays                    TooDeep
a text string that is not UTF-8      BadText       62fffe
```

They run on any machine with no board, which is the point — a board cannot be
asked these thirty thousand times and a `cargo test` can.

### `skip` is not `ignore`

Fields this device does not use — `excludeList`, `extensions`, `options`,
`pinUvAuthParam` — are stepped over rather than parsed. But `skip` still walks
every byte and still checks it: a map nested inside a field nobody reads has its
keys checked for order, and a length that lies inside it is still refused.

**Skipping something without checking it is how a parser comes to disagree with
the thing that wrote it**, and that disagreement is where a second
implementation reads a different message from the same bytes.

## What it refuses that a permissive reader would not

Three of the six malformed cases are **valid CBOR**. A general-purpose decoder
accepts all three and hands back a structure:

- `mc-noncanonical` — a map header written in two bytes where one would do;
- `mc-trailing` — a complete map with a byte after it;
- and, in the crate's tests, integers written wider than they need to be.

CTAP2 requires the canonical form, so accepting these would mean this device and
a stricter one disagree about which messages exist. **It refuses them, and
that is a decision with a cost**: whether a real browser ever sends something
this strict reader rejects is untested here and is written down as an open
question rather than assumed away.

## What is not verified here

- **It still cannot make a credential.** `CTAP2_ERR_OPERATION_DENIED` is the
  honest answer and the experiment ends there.
- **Strictness on input is not measured against a real client.** Only
  hand-built requests have been sent. A browser that sends non-canonical CBOR
  would be refused by this device, and finding out whether one does belongs to
  the experiment that first involves a browser.
- **The parser reads four of `makeCredential`'s parameters.** `excludeList`,
  `extensions`, `options` and `pinUvAuthParam` are skipped — checked, but not
  understood. A device that acted on this request would have to read them.
- **`MAX_ALGS` is eight.** A caller offering more has the rest recorded as
  truncated rather than dropped silently, because a refusal about the wrong
  algorithm is worse than a refusal.
- **No cryptography.** `check.sh` fails if a crypto dependency or key material
  appears — as it has since exp168.

## Running it

```console
cd experiments/exp170-a-map-somebody-else-wrote
./check.sh          # crate tests, twenty live cases, seven transcript corruptions
./drive.sh          # one round by hand, both voices
python3 ctaphid.py mc-lying-length
```

```console
python3 verify.py < capture.txt
```

`ctaphid.py` builds the CBOR by hand, including the shapes a library would
refuse to produce — which is exactly why there is not one in it.

## Expected output

Pasted from a real run on a Pico 2, Ubuntu, 2026-08-22. Trimmed; the full
transcript is [`capture.txt`](./capture.txt).

```console
>>> host: case mc-good
    {"status_name": "CTAP2_ERR_OPERATION_DENIED", "request_bytes": 114, ...}
>>> host: case mc-lying-length
    {"status_name": "CTAP2_ERR_INVALID_CBOR", "request_bytes": 114, ...}
>>> host: case mc-missing-cdh
    {"status_name": "CTAP2_ERR_MISSING_PARAMETER", "request_bytes": 79, ...}
>>> host: case mc-no-es256
    {"status_name": "CTAP2_ERR_UNSUPPORTED_ALGORITHM", "request_bytes": 116, ...}

>>> board: what it said while all of that happened
    [   12780 ms]     rp.id      = "example.test"
    [   12840 ms]     user.id    = 4 bytes
    [   12900 ms]     clientData = 0001020304050607 (32 bytes)
    [   12960 ms]     alg        = -7  (ES256)
    [   13020 ms]   ES256 was offered, and this device still has no key to sign with.
    [   13080 ms]   refusing with 0x27, having understood the request.
    [   13500 ms]   makeCredential refused: a length that runs past the message
    [   13560 ms]   status 0x12, and nothing was read past the buffer.
```

`./check.sh` on the same board:

```console
PASS  crates/cbor's tests pass, including RFC 8949's own examples
PASS  the reader bounds-checks every length against its own buffer, with checked_add
PASS  the reader indexes its buffer in exactly one place, inside take()
PASS  nesting is depth-limited: a deep message is refused, not a stack overflow
PASS  CTAP2_ERR_INVALID_CBOR is sent when the bytes were wrong
PASS  CTAP2_ERR_MISSING_PARAMETER is sent when a required field was absent
PASS  CTAP2_ERR_OPERATION_DENIED is sent when it was understood and refused anyway
PASS  the parser borrows from the message rather than copying out of it
PASS  an algorithm list longer than the device records is recorded as truncated
PASS  trailing bytes after a complete request are refused, not ignored
PASS  verify.py rejects a hostile length that was not refused (got DISAGREE)
PASS  verify.py rejects a run in which nothing was ever parsed (got DISAGREE)
PASS  verify.py rejects a refusal relabelled as a failure to read (got DISAGREE)
PASS  a request was read and its fields reported, not merely refused
PASS  a length that runs past the message is refused by a board still talking
PASS  a request understood in full still gets a refusal, with its own status
```

## Four things to take away

1. **The parser is the attack surface, and it deserves its own rung.**
   `makeCredential` is six things; five of them cannot be got wrong by somebody
   else's bytes and one of them can.
2. **One bounds check, in one place, countable.** `check.sh` fails if the reader
   grows a second way to index its buffer. That is a cheaper guarantee than
   auditing every call site and it is the one that stays true as the code
   changes.
3. **Understood-and-refused is a different answer from could-not-read**, and a
   device that cannot tell you which is a device you debug by guessing. Three
   status codes, and the log names the five distinct mistakes the protocol has
   one number for.
4. **Skipping is not ignoring.** Fields this device does not use are still
   walked and still checked, because a parser that skips unchecked is a parser
   that has quietly agreed to a different message than the sender wrote.

## Next

**Something to register.** The parser is done, so what is left of
`makeCredential` is the cryptography: ES256 over the authenticator data and the
client data hash, self attestation, user presence on the BOOTSEL button
([exp106](../exp106-bootsel-button/)), and the credential's private key
**wrapped into the credential ID** rather than stored.

That last choice is what makes the [identity road](../README.md#the-identity-road)
the next hinge: something has to hold the wrapping key, and
[`docs/can-this-chip-keep-a-secret.md`](../../docs/can-this-chip-keep-a-secret.md)
is eight experiments' worth of what this chip will and will not do about that.
It is also the first point at which a browser will accept anything.
