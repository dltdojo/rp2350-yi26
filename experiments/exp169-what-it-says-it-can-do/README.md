# exp169 — what it says it can do

One CTAP2 command, and it is the one where a device describes itself:
**`authenticatorGetInfo`**. Still no signing, still no credential, still no
secret — but for the first time a host **parses a body** rather than getting its
own bytes back, and for the first time this device has to make a **claim**.

The second experiment on the
[authenticator road](../README.md#the-authenticator-road), built on
[exp168](../exp168-a-security-key-that-knows-nothing/)'s transport, which is
unchanged apart from one bit.

> **Verified on hardware, 2026-08-22.** Sixteen cases. `fido2-token -I` reads
> the device's own description and prints it: `caps: 0x0c (nowink, cbor,
> nomsg)`, an all-zero AAGUID, `maxmsgsiz: 1024`, and **no version line at
> all** — because the honest build claims none. The build that claims
> `FIDO_2_0` is driven too, and a tool that believes it gets
> `FIDO_ERR_INTERNAL`. See [Expected output](#expected-output).

## The claim it has no obvious honest way to make

`getInfo`'s key `0x01` is `versions`: the CTAP versions this authenticator
supports. This one supports *part of* CTAP2 — `getInfo` and nothing else. There
is no string for that.

exp168 found the opposite one layer down: the CTAPHID capability byte is
fine-grained enough to say **"no CBOR, no MSG"**, and `fido2-token` printed
exactly that. Here the vocabulary looked like it ran out, and the choice looked
like claiming `FIDO_2_0` — which is not true — or claiming nothing, which might
not be legal or might not be useful.

**So both were built and both were measured**, rather than one being chosen and
defended in prose. `EXP169_CLAIM=none` is the default, because a plain
`cargo build` should not ship the lie, and `check.sh` fails if that default ever
changes.

### The measurement, and it came out better than the interrogation guessed

| build | `fido2-token -I` | a tool that acts on it |
|---|---|---|
| `none` — `versions: []` | accepted; every other field parsed; **no version line** | — |
| `fido2` — `versions: ["FIDO_2_0"]` | accepted; `version strings: FIDO_2_0` | `fido2-token: fido_credman_get_dev_metadata: **FIDO_ERR_INTERNAL**` |

> **The honest option exists and works.** An empty `versions` array is
> structurally valid, `libfido2` handles it without complaint, and the device
> still reports its AAGUID, its maximum message size and its capabilities. The
> vocabulary did not run out; saying nothing *is* the way to say nothing.

And the overclaim produces this road's least useful sentence. `FIDO_ERR_INTERNAL`
is the desktop cousin of the *"An unknown error occurred while talking to the
credential manager"* that
[the road's own history](../README.md#the-authenticator-road) is built around: a
generic failure, with the interesting detail never reaching the caller.

The overclaiming build still refuses `makeCredential` and `getAssertion` **by
name**, with `CTAP1_ERR_INVALID_COMMAND`, because that is the only apology the
protocol has room for. `check.sh` fails if those refusals are ever removed.

## Canonical CBOR is a property a host can check

CTAP2 does not merely want CBOR. It wants the **canonical** form:

- every integer in its shortest encoding,
- definite lengths everywhere,
- and map keys in ascending order.

Two encoders that disagree about any of those produce different bytes for the
same data, and a host that hashes or compares a response will call one of them
wrong.

[`crates/cbor`](../../crates/cbor/) is written for exactly that subset and
**refuses to produce anything else**: `Writer::key` returns `KeyOutOfOrder` if a
key does not follow the last one, and a container whose length lies is an error
at `finish` rather than a message a reader cannot recover from. Nine tests,
including RFC 8949's own example table, and they run on any machine with no
board — [`crates/fat12`](../../crates/fat12/)'s shape.

`verify.py` then decodes what the board actually sent with a reader that
**fails on anything non-canonical rather than normalising it**:

```
non-canonical int   REJECTED: 1 written in three bytes; it fits in fewer
keys out of order   REJECTED: map key 1 does not follow 3
indefinite length   REJECTED: an indefinite length, which CTAP2 forbids
```

That is the point of writing a reader rather than borrowing one: a permissive
decoder accepts all three and tells you nothing.

## The response, and each key is a decision

```
a3                          map(3)
   01 80                    versions: []            <- the claim, see above
   03 50 00*16              aaguid: sixteen zeros
   05 19 04 00              maxMsgSize: 1024
```

- **The AAGUID is all zero, and that is a statement.** It identifies an
  authenticator *model* to a relying party. A device with no attestation
  identity reports zeros; inventing one would be claiming to be a product that
  exists.
- **`maxMsgSize` is the limit the transport actually enforces.** exp168's
  `MAX_MESSAGE`, not a number chosen for the response. A device whose declared
  limit and real limit differ is one whose refusals look arbitrary.
- **The keys ascend — 1, 3, 5 — in the source, not sorted at run time**, so the
  firmware is readable as canonical. `check.sh` extracts them and checks the
  order.

## One bit changed in the transport

exp168 sent `caps: 0x08` — `nocbor, nomsg`. This sends `0x0c`.

`CAPABILITY_NMSG` stays set because CTAP1/U2F really is not implemented, and
that is now checkable rather than declarative: the `unknown` case sends
`CTAPHID_MSG` and requires `ERR_INVALID_CMD` back. **The device is tested
against its own declaration.**

## The sixteen cases

exp168's twelve, unchanged, plus four:

| case | what it sends | what must come back |
|---|---|---|
| `getinfo` | `CTAPHID_CBOR` + `0x04` | `CTAP2_OK` and a canonical map |
| `getinfo-params` | `0x04` with a parameter | `CTAP1_ERR_INVALID_LENGTH` |
| `makecred` | `0x01` | `CTAP1_ERR_INVALID_COMMAND` |
| `ctap-unknown` | `0xEE` | `CTAP1_ERR_INVALID_COMMAND` |

Two things `verify.py` derives about them that a careless reading would miss:

- **a CTAP2 refusal must arrive as `CTAPHID_CBOR`, not `CTAPHID_ERROR`.** A
  device that answered a CTAP2 command with a transport error would look
  "refused" and be wrong about which layer said no — exp136's concern, one layer
  up again.
- **a refusal carries a status byte and nothing else.** Bytes after it are a
  response the host will try to parse.

## What is not verified here

- **It is still not a security key.** `makeCredential` and `getAssertion` are
  refused by name. No browser has seen this device and none would get anywhere.
- **`versions: []` is legal to `libfido2`.** Whether a *browser* tolerates it is
  untested and is a different question — CTAP2's own text requires the field,
  not a particular length.
- **`FIDO_ERR_INTERNAL` is what one tool said.** It is not a claim about what
  every client does with an overclaim, and Android in particular has a history
  the road records and this experiment did not reproduce.
- **The CBOR subset is a subset.** No negative integers, no floats, no tags, no
  indefinite lengths, no nesting past four. A real authenticator needs more, and
  [`crates/cbor`](../../crates/cbor/) says so about itself.
- **No cryptography.** `check.sh` fails if a crypto dependency or key material
  appears.

## Running it

```console
cd experiments/exp169-what-it-says-it-can-do
./check.sh          # builds both claims, drives sixteen cases, grades all of them
./drive.sh          # one round by hand, both builds, both voices
python3 ctaphid.py getinfo
```

```console
python3 verify.py < capture.txt
```

`verify.py` decodes the response with a canonical-only reader, requires the
packet counts to follow from the byte counts, requires each deliberate mistake
to draw the status the specification names, requires a refusal to carry no body,
and requires the transcript to contain **both** claims — because one half of a
comparison is not a comparison.

## Expected output

Pasted from a real run on a Pico 2, Ubuntu, 2026-08-22. Trimmed; the full
transcript is [`capture.txt`](./capture.txt).

```console
>>> host: case getinfo
    {"case": "getinfo", ..., "status_name": "CTAP2_OK",
     "cbor": "a3018003500000000000000000000000000000000005190400"}
>>> host: case getinfo-params
    {"status_name": "CTAP1_ERR_INVALID_LENGTH", "cbor": ""}
>>> host: case makecred
    {"status_name": "CTAP1_ERR_INVALID_COMMAND", "cbor": ""}

>>> host: fido2-token -I on the build that claims nothing
    caps: 0x0c (nowink, cbor, nomsg)
    aaguid: 00000000000000000000000000000000
    maxmsgsiz: 1024

>>> board: what it said while all of that happened
    [    3518 ms]   versions claim = "none" (0 entries)
    [    3578 ms]   getInfo body is 25 bytes: a3018003500000000000000000000000000000000005190400

>>> host: now the build that claims FIDO_2_0, which is not true of it
    caps: 0x0c (nowink, cbor, nomsg)
    version strings: FIDO_2_0
>>> host: and a tool that believes the claim and acts on it
    fido2-token: fido_credman_get_dev_metadata: FIDO_ERR_INTERNAL
```

`./check.sh` on the same board:

```console
PASS  crates/cbor's tests pass, including RFC 8949's own examples
PASS  the writer refuses a map key out of order rather than emitting it
PASS  the none build compiles and converts (58368 bytes)
PASS  the fido2 build compiles and converts (58368 bytes)
PASS  a plain cargo build claims no CTAP version: the default is the honest one
PASS  getInfo's map keys are written in ascending order (0x01 0x03 0x05 )
PASS  the AAGUID is sixteen zero bytes: no attestation identity is claimed
PASS  makeCredential and getAssertion are refused by name, not ignored
PASS  the capability byte announces CBOR and still denies MSG
PASS  verify.py rejects a getInfo response with a non-canonical integer (got DISAGREE)
PASS  verify.py rejects a refusal that carried a response body (got DISAGREE)
PASS  fido2-token -I reads the capability byte and sees CBOR
PASS  the declared maximum message size is the one the transport enforces
PASS  the overclaiming build is driven too, so the claim is measured and not argued
PASS  a tool that believes the claim fails, and the transcript holds what it said
```

## Four things to take away

1. **Say nothing rather than say something untrue, and check that saying nothing
   works.** The interrogation for this experiment assumed the protocol left no
   honest option. Building both and measuring found one — and the cost of the
   dishonest option is a generic error a caller cannot debug.
2. **Canonical is not a style; it is the format.** Shortest integers, definite
   lengths, ascending keys. An encoder that merely *permits* canonical output
   will emit something else eventually, so this one refuses.
3. **A declaration is testable.** The capability byte says `nomsg`, so the run
   sends `CTAPHID_MSG` and requires a refusal. A device that declares one thing
   and does another is worse than one that declares nothing.
4. **Which layer refused matters as much as whether it refused.** A CTAP2 error
   arrives as a `CTAPHID_CBOR` message with a status byte, not as a transport
   error — and a reader who cannot tell them apart blames the wrong half.

## Next

**Something to register.** `authenticatorMakeCredential`, which is where the
cryptography arrives: ES256 over the client data, self attestation, user
presence on the BOOTSEL button ([exp106](../exp106-bootsel-button/)), and the
credential's private key **wrapped into the credential ID** rather than stored —
which is the choice that makes the [identity road](../README.md#the-identity-road)
the next hinge, because something has to hold the wrapping key.

It is also the point where `versions: ["FIDO_2_0"]` stops being an overclaim,
and the first place a browser will accept anything.
