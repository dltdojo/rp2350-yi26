# exp173 — a client that is not ours

Every experiment from [exp168](../exp168-a-security-key-that-knows-nothing/) to
[exp172](../exp172-the-same-key-twice/) drove this board with a CTAPHID client
written for this repository. So every message the board ever saw was one this
repository also wrote.

**These are somebody else's.** `fido2-token`, `fido2-cred` and `fido2-assert`,
from `libfido2` — their CBOR, their field order, their idea of what an
authenticator owes a caller. What they refuse is the finding.

The sixth on the [authenticator road](../README.md#the-authenticator-road).

> **Verified on hardware, 2026-08-22, both builds.** `libfido2` makes a
> credential, **verifies the self attestation**, gets an assertion with it, and
> the assertion verifies against the key the credential handed over. And the one
> thing it refused for five experiments turns out to have nothing to do with the
> cryptography. See [Expected output](#expected-output).

## The refusal, and what it was actually about

For as long as this board has made credentials, `fido2-cred -V` has said:

```
fido2-cred: fido_cred_verify_self: FIDO_ERR_INVALID_PARAM
```

An invalid parameter, in a self attestation, from a device whose signature this
repository's own verifier had been checking successfully since exp171. The
obvious reading is that something in the attestation is wrong.

**It is the user-presence bit.** The same firmware, the same client, one press
of BOOTSEL:

| | `EXP173_UP=none` | `EXP173_UP=button`, pressed |
|---|---|---|
| `fido2-token -I` options | `nork, noup` | `nork, up` |
| credential flags | `0x40` | `0x41` |
| **`fido2-cred -V`** | **refused** | **verified, and wrote the public key out** |
| assertion flags | `0x00` | `0x01` |
| signature verifies against the registered key | **True** | **True** |

The last row is the one that settles it. **The signature was always valid.**
`libfido2` was enforcing WebAuthn's rule — a credential made without a person
present is not a credential — and reporting it through the only error the API
has room for.

`verify.py`'s core is that implication, in both directions:

```
the user-presence bit is 0  <->  fido2-cred -V refuses the credential
```

A transcript showing `UP=False` with a verification that passed, or `UP=True`
with one that was refused, fails — because either would mean the refusal was
never about presence and this experiment's conclusion is wrong.

### What that costs backwards

Every credential exp171 and exp172 made in their unattended builds is one **no
client will accept**, and now there is a name for why. Those experiments said
so — *"no client will take this"* — and this is the sentence measured rather
than predicted.

## `FIDO_2_0` is earned here

[exp169](../exp169-what-it-says-it-can-do/) built a device that claimed
`FIDO_2_0` with only `getInfo` behind it, and measured the cost: `libfido2`
believed the claim and a tool that acted on it returned `FIDO_ERR_INTERNAL`.
The honest build claimed nothing.

exp171 added `makeCredential` and exp172 added `getAssertion`, which is what
`FIDO_2_0` names. **The string that was a lie three experiments ago is now a
description**, and `check.sh` fails if the claim and the two commands ever stop
moving together.

It is still not the whole of CTAP2 — no `clientPIN`, no resident credentials,
no extensions — and the specification does not require those of a `FIDO_2_0`
authenticator.

### And the options map is a measurement, not an aspiration

`getInfo` grows key `0x04`:

```text
{"rk": false, "up": <this build asks a person>}
```

`rk` is resident credentials, which a device that stores nothing cannot have.
`up` says whether the authenticator can ask at all — **true in the `button`
build and false in the one that asks nobody**, because a capability a build does
not have is one it must not announce. `verify.py` fails if the declaration and
the flags disagree.

## Something the specification does not mention

`libfido2`'s tools print the authenticator data **wrapped in its CBOR
byte-string header**:

```text
authData=180B (cbor header 58b4)     0x58 0xb4  =  byte string, 180 bytes
authData=37B  (cbor header 5825)     0x58 0x25  =  byte string, 37 bytes
```

A reader that assumes raw bytes is two bytes off, reads `rpIdHash[30]` as the
flags byte, and gets a plausible-looking answer. **This experiment made exactly
that mistake** and reported `flags=0x47` — user present, user verified — for a
build that sets neither, and for a moment it looked like the board was lying.

It is recorded in `verify.py` as a required note rather than a comment: a
transcript with no CBOR header in it fails, because nothing in it would say how
the bytes were framed.

## What is not verified here

- **No browser has driven this device.** `libfido2` is a real client and is not
  a browser: it does not enforce origins, does not build client data, and does
  not have the strictness history the
  [road](../README.md#the-authenticator-road) records for Android. That is the
  next experiment and it is what the road was for.
- **`fido2-cred -V` verifying is not a browser accepting.** It checks the
  attestation; a browser checks that and everything around it.
- **The strict CBOR reader has still not been contradicted.** `libfido2` sends
  canonical CBOR, so [exp170](../exp170-a-map-somebody-else-wrote/)'s refusals
  have never fired against a real client. Whether anything sends what this
  device would reject is still open.
- **`sign_count` is zero and the device secret is a compiled-in test key**, both
  carried forward from exp171 and exp172 unchanged.
- **`options` says `noup` in the unattended build**, which is honest and means a
  client that reads it knows not to bother. Nothing here measures whether one
  does.

## Running it

```console
cd experiments/exp173-a-client-that-is-not-ours
./check.sh          # both builds, the libfido2 round trip, five corruptions
./roundtrip.sh      # one round trip, driven entirely by libfido2's own tools
```

The build that asks a person, and the one that produces the passing half of the
comparison:

```console
EXP173_UP=button cargo build --release
elf2flash convert -b rp2350 \
  target/thumbv8m.main-none-eabihf/release/exp173-a-client-that-is-not-ours \
  target/exp173-button.uf2
yi26 bootsel && yi26 pflash target/exp173-button.uf2
./roundtrip.sh      # hold BOOTSEL: it is asked twice, once to register and once to assert
```

```console
python3 verify.py < capture-button.txt
```

## Expected output

Pasted from real runs on a Pico 2, Ubuntu, 2026-08-22.
[`capture.txt`](./capture.txt) is the build that asks nobody;
[`capture-button.txt`](./capture-button.txt) is the same firmware with a finger
on the button.

Asking nobody:

```console
>>> host: fido2-token -I, which is libfido2 reading what the device says it can do
    version strings: FIDO_2_0
    options: nork, noup
>>> host: fido2-cred -M: libfido2 makes a credential
    fmt=packed authData=180B (cbor header 58b4)
    flags=0x40 UP=False UV=False AT=True ED=False
>>> host: fido2-cred -V: libfido2 verifies the self attestation it was just handed
    REFUSED: fido2-cred: fido_cred_verify_self: FIDO_ERR_INVALID_PARAM
>>> host: and the same assertion checked against the key this repository extracted
    signature verifies against the registered key: True
```

With BOOTSEL held:

```console
    options: nork, up
    flags=0x41 UP=True UV=False AT=True ED=False
>>> host: fido2-cred -V: libfido2 verifies the self attestation it was just handed
    verified, and wrote the public key out
    flags=0x01 UP=True UV=False AT=False ED=False
    signature verifies against the registered key: True
```

`./check.sh` on the same board:

```console
PASS  FIDO_2_0 is claimed and both commands it names are implemented
PASS  the options map's up follows the build rather than being hard-coded
PASS  verify.py replays capture.txt
PASS  verify.py replays capture-button.txt
PASS  the implication holds in both directions: UP=0 refused, UP=1 verified
PASS  verify.py rejects a credential with no user present that was accepted (got DISAGREE)
PASS  verify.py rejects a credential with a user present that was refused (got DISAGREE)
PASS  verify.py rejects options that contradict the flags produced (got DISAGREE)
PASS  a press is on record: UP=1, and libfido2 verified the self attestation
PASS  the pressed transcript contains no refusal at all
PASS  libfido2 made a credential with its own CBOR, not ours
PASS  libfido2 used that credential to get an assertion
PASS  the assertion verifies against the key the credential handed over
```

## Four things to take away

1. **An error code is a name for a rule, not a diagnosis.**
   `FIDO_ERR_INVALID_PARAM` on a self attestation reads as "your attestation is
   malformed" and meant "your user was not present". Five experiments went past
   it, and the only way to tell those apart was to change the one bit and look.
2. **Drive it with something you did not write.** Every message before this one
   came from the same repository as the firmware, and a client and a device that
   agree because they were written together agree about nothing.
3. **A claim earns itself by the commands behind it.** `FIDO_2_0` was a lie in
   exp169 and is a description here, and nothing about the string changed.
4. **Host tools frame things the specification does not mention.** Two bytes of
   CBOR header made this experiment briefly believe the board was setting a
   user-verified flag it does not have.

## Next

**A browser.** Everything a client needs is here and a real client has used all
of it. What a browser adds is origins, client data it builds itself, a
permissions UI, and — on Android — an implementation with a documented history
of being stricter than the desktop one about response shapes.

The two things most likely to break are already named:
[exp170](../exp170-a-map-somebody-else-wrote/)'s strict CBOR reader, which no
real client has yet contradicted, and whatever a browser does with an
authenticator that has no `clientPIN` and no resident credentials.
