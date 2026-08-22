# exp171 — a credential nobody asked for

The cryptography arrives. This board makes a **real WebAuthn credential** —
P-256, self-attested, with an authenticator data structure a relying party
parses and a signature it verifies — and the private key **is never stored
anywhere**.

The fourth experiment on the
[authenticator road](../README.md#the-authenticator-road).

> **Verified on hardware, 2026-08-22, both builds.** A `makeCredential` request produces a
> 276-byte response whose signature is checked off the board by a different
> elliptic-curve library, with a bit flipped and the check required to fail
> first. **Deriving the key costs 44.5 ms and signing costs 53.8 ms.** The
> credential ID is 48 bytes, the AAGUID is sixteen zeros, and the user-presence
> bit is **0** — because nothing pressed anything. See
> [Expected output](#expected-output).

## The name is the finding

A FIDO2 authenticator must ask a person before it makes a credential, and says
whether it did in one bit of the authenticator data. **The easy wrong thing is
to set that bit anyway**, and it is easy because nothing in the protocol checks
it — the bit is the device's own word.

So user presence is a build input and **both settings are honest**:

| build | what it does | the UP bit |
|---|---|---|
| `EXP171_UP=none` (default) | asks nobody, and says so in its log | **0** |
| `EXP171_UP=button` | waits up to ten seconds for BOOTSEL | **1** if pressed, and the request is refused if not |

A client that requires user presence will refuse the first, which is correct and
is the point. `check.sh` drives the `none` build unattended and fails if the UP
bit is ever 1 in it.

**Neither build ever sets the bit without earning it.** That sentence is the
whole reason this is a two-build experiment rather than a one-line decision.

## The key is derived, not stored

```text
credential ID  =  nonce (32, from the TRNG)  ||  HMAC(secret, "id" ‖ nonce ‖ rpIdHash)[..16]
private key    =  HMAC(secret, "key" ‖ counter ‖ nonce ‖ rpIdHash), rejected until valid
```

Nothing is written to flash and nothing survives the function that used it. The
key exists for the 98 ms it takes to make a credential and then it is gone,
which is [exp163](../exp163-how-long-is-a-secret-in-the-open/)'s subject — and
**exp163's limit applies here unchanged**: while it exists it is in SRAM, and
exp163 measured for how long a second core can see such a thing.

Three decisions inside that:

- **The credential ID carries a tag.** Without one, anybody's forty-eight bytes
  would be a credential ID this device derives a key for. Nothing in *this*
  experiment reads a credential ID back — that is `getAssertion`'s job — and
  building it unauthenticated now would be leaving a hole for a later experiment
  to fall into.
- **The derivation is bound to `rpIdHash`.** Free, and it means a credential
  made for one relying party yields a different key for another.
- **The scalar is found by rejection, not by reducing a hash modulo *n*.**
  Reduction is biased; bias is a famous way to lose an ECDSA key. This is a
  long-term key rather than a per-signature nonce so the exposure would be
  smaller, and the habit is worth keeping either way. `check.sh` enforces it.

## The device secret says what it is

```
const DEVICE_SECRET: [u8; 32] = [ ... ];   // "not a secret. this is a test key"
```

Thirty-two bytes of ASCII, compiled in, spelling their own warning — so
[exp166](../exp166-whose-firmware-will-it-accept/)'s byte search over a `.uf2`
finds a sentence rather than a random-looking key. `check.sh` decodes the
constant and fails if it stops saying that.

**This is the [identity road](../README.md#the-identity-road) arriving with a
name.** Whoever holds these bytes can reproduce every credential this board will
ever make, and the reason they are compiled in is that **this part has no secret
that is the same across reboots and written nowhere** —
[`docs/can-this-chip-keep-a-secret.md`](../../docs/can-this-chip-keep-a-secret.md)
is eight experiments' worth of why.

## Self attestation comes as a set

`fmt` is `"packed"`, the signature is made with the credential's own private key,
and there is no certificate. That is what an authenticator with no attestation
identity is supposed to do, and the specification pairs it with an **all-zero
AAGUID** — a device that shipped a non-zero one with self attestation would be
claiming a model it cannot prove. `check.sh` checks all three together, because
getting one right and another wrong is how a device copies somebody else's
constant.

The **UV** flag is defined in the source and never set anywhere: this device
cannot verify anybody, and a flag it cannot earn is one it must not raise.

## Checked by somebody else's library

The response is verified the way a relying party does it, in `ctaphid.py`, using
`cryptography` — a different implementation from the `p256` that made it:

```json
"rp_id_hash_matches": true,   "aaguid_all_zero": true,
"cose_kty": 2, "cose_alg": -7, "cose_crv": 1, "coordinate_bytes": [32, 32],
"att_has_x5c": false,         "sign_count": 0,
"signature_valid": true,      "tamper_rejected": true
```

`tamper_rejected` is [exp159](../exp159-a-key-that-was-never-in-flash/)'s rule:
one bit of the authenticator data is flipped and the same check is required to
**fail** before the pass is reported. A signature that verifies proves nothing
until the verifier has been seen to say no.

## What it costs

| | on this part |
|---|---|
| derive the key (HMAC, plus the public point) | **44.5 ms** |
| sign the authenticator data and client data hash | **53.8 ms** |
| authenticator data | 180 bytes (COSE key 77) |
| whole response | 276 bytes, five CTAPHID packets |

For comparison, [exp159](../exp159-a-key-that-was-never-in-flash/) measured a
bare P-256 signature at 61 ms and
[exp166](../exp166-whose-firmware-will-it-accept/) a verification at 97.7 ms, so
these are in the same family rather than new numbers.

## What is not verified here

- **`sign_count` is always zero.** A counter that survives a reset is a counter
  that is stored, and this device stores nothing. A relying party that enforces
  monotonicity will notice; that is a limit, not a bug.
- **No credential can be used yet.** `getAssertion` is the next experiment, and
  it is what will read the credential ID's tag back.
- **No browser has seen this.** With `versions: []` and `UP=0`, none would take
  it. What a real client does with a device this strict is the road's open
  question.
- **The device secret is a test key**, and everything above is reproducible by
  anybody holding the firmware. That is the honest state of this road until the
  identity road answers.
- **Nothing here is constant-time**, and no claim is made about side channels.

### One thing the timeout measured for free

The `button` build holds the transaction open for ten seconds with no
`CTAPHID_KEEPALIVE`, and **the host waited** — `libfido2` did not give up. CTAP
has `KEEPALIVE` for exactly this, and whether a *browser*'s patience is shorter
is what the next experiment about presence will be about.

## Running it

```console
cd experiments/exp171-a-credential-nobody-asked-for
./check.sh                       # both builds, twenty cases, the credential checked
./drive.sh                       # one round by hand, both voices
python3 ctaphid.py mc-good       # one credential, verified as a relying party would
```

The build that asks a person, and the only part of this experiment that needs
one:

```console
EXP171_UP=button cargo build --release
elf2flash convert -b rp2350 \
  target/thumbv8m.main-none-eabihf/release/exp171-a-credential-nobody-asked-for \
  target/exp171-button.uf2
yi26 bootsel && yi26 pflash target/exp171-button.uf2
python3 ctaphid.py mc-good       # then press BOOTSEL within ten seconds
```

## Expected output

Pasted from a real run on a Pico 2, Ubuntu, 2026-08-22. Trimmed; the full
transcript is [`capture.txt`](./capture.txt).

```console
>>> host: case mc-good
    {"status_name": "CTAP2_OK", "response_bytes": 276, "credential": {
       "fmt": "packed", "rp_id_hash_matches": true, "user_present": false,
       "aaguid_all_zero": true, "credential_id_len": 48, "cose_alg": -7,
       "att_has_x5c": false, "signature_valid": true, "tamper_rejected": true}}

>>> board: what it said while all of that happened
    [   14795 ms]     rp.id      = "example.test"
    [   14915 ms]     alg        = -7  (ES256)
    [   14975 ms]   nobody is asked in this build: the UP bit will be 0.
    [   21464 ms]   credential made: authData 180 B (COSE key 77 B), response 276 B
    [   21524 ms]   derive 44529 us, sign 53769 us, UP bit 0
    [   21584 ms]   the private key is not stored; it was derived and is gone.
```

The `button` build, **with somebody pressing** — the whole of
[`capture-button.txt`](./capture-button.txt):

```console
[   93696 ms]   waiting for BOOTSEL. Nothing is sent while this runs.
[   93756 ms]   pressed after 0 ms
[   96882 ms]   credential made: authData 180 B (COSE key 77 B), response 275 B
[   96942 ms]   derive 44543 us, sign 53835 us, UP bit 1
```

`flags` comes back `0x41` — `AT | UP` — and the relying party's own check reads
`"user_present": true` beside `"signature_valid": true`.

And with **nobody** pressing, which is the same build and the other answer:

```console
[    7439 ms]   waiting for BOOTSEL. Nothing is sent while this runs.
[   17511 ms]   nobody pressed anything after 10011 ms
status: CTAP2_ERR_OPERATION_DENIED
```

**`pressed after 0 ms` is worth reading twice.** The button was held down before
the request arrived, so the firmware saw it on its first poll. The ten seconds
is a *timeout*, not a reaction window, and a device that made you catch a
ten-second gap would be a worse one to use.

`./check.sh` on the same board:

```console
PASS  exactly three cryptographic dependencies: p256, sha2, hmac
PASS  no private key is stored in a static: every key is derived and dropped
PASS  the credential key is derived from the device secret and the relying party
PASS  the device secret spells 'not a secret. this is a test key' in its own bytes
PASS  the AAGUID is zero, which self attestation requires
PASS  the attestation carries no certificate: it is self attestation throughout
PASS  the UV flag is defined and never set: a flag it cannot earn
PASS  the scalar is found by rejection, not by reducing a hash modulo n
PASS  verify.py rejects a tampered signature that still verified (got DISAGREE)
PASS  verify.py rejects an attestation signature that does not verify (got DISAGREE)
PASS  verify.py rejects a device claiming it verified a user (got DISAGREE)
PASS  verify.py rejects self attestation with a non-zero AAGUID (got DISAGREE)
PASS  a credential was made, and its cost is in the transcript
PASS  the board says the key was derived rather than kept
PASS  the UP bit is 0 in the build that asks nobody: no client will take this
```

## Four things to take away

1. **The bit that says a person was there is the device's own word, and nothing
   checks it.** Which is exactly why a device that sets it without asking is
   telling the only lie this road must not tell — and why user presence is two
   builds here rather than one line. Both are on the board: `0x40` with nobody
   asked, `0x41` with a finger on the button.
2. **A key that is derived is a key that cannot be stolen at rest**, and is
   exactly as exposed in use as any other. exp163 measured that, and a
   derivation scheme does not change it.
3. **Self attestation, a zero AAGUID and no certificate are one decision, not
   three.** Getting one right and another wrong is how a device ends up claiming
   a model it cannot prove.
4. **A signature that verifies proves nothing until the verifier has said no.**
   One flipped bit, checked by a library that did not make the signature.

## Next

**Something to log in with.** `authenticatorGetAssertion` reads the credential
ID back, checks the tag this experiment put in it, re-derives the same private
key, and signs a fresh challenge. It is one more command and it is where the
credential stops being a thing this board emitted and starts being a thing it
**remembers without remembering** — the only kind of memory a device that stores
nothing has.
