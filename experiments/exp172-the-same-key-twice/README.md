# exp172 — the same key twice

[exp171](../exp171-a-credential-nobody-asked-for/) made a credential and threw
the private key away. This one gets it back — from forty-eight bytes somebody
hands over — and signs with it.

**Nothing was stored between the two.** That is the experiment.

The fifth on the [authenticator road](../README.md#the-authenticator-road).

> **Verified on hardware, 2026-08-22, both builds.** Twenty-seven cases. A
> registration and an assertion, minutes apart, and the assertion **verifies
> against the public key registration handed over**. A forged tag, a credential
> from a different relying party, and one with no tag at all are all refused
> **before anything is derived**. With BOOTSEL held, both halves report `UP bit
> 1`. See [Expected output](#expected-output).

## Memory without storage

A device that stores nothing cannot look a credential up. So the credential ID
*is* the lookup:

```text
credential ID  =  nonce (32)  ||  HMAC(secret, "id" ‖ nonce ‖ rpIdHash)[..16]
```

Given it back, the board recomputes the tag with the `rpIdHash` from **this**
request. If it matches, those bytes are one it made, for this relying party, and
the same `derive_key` that produced the credential produces the key again.

The numbers say it happened twice:

```
derive 44460 us, sign 53786 us, UP bit 1    <- registration
derive 44448 us, sign 53685 us, UP bit 1    <- the assertion, minutes later
```

Twelve microseconds apart, because it is the same work.

## The tag is the whole security property

Without it, forty-eight bytes of anything would be a credential ID this device
derives a key for. With it bound to `rpIdHash`, a credential collected from one
site cannot be used at another — and `ga-other-rp` is that case, driven:

| case | what it offers | what comes back |
|---|---|---|
| `ga-roundtrip` | the real credential, same relying party | **`CTAP2_OK`**, and it verifies |
| `ga-forged` | one byte of the tag turned over | `CTAP2_ERR_NO_CREDENTIALS` |
| `ga-other-rp` | **the real credential, a different relying party** | `CTAP2_ERR_NO_CREDENTIALS` |
| `ga-wrong-length` | the nonce with no tag | `CTAP2_ERR_NO_CREDENTIALS` |
| `ga-empty-allow` | an allow list with nothing in it | `CTAP2_ERR_NO_CREDENTIALS` |
| `ga-no-allow` | no allow list, meaning "use a resident credential" | `CTAP2_ERR_NO_CREDENTIALS` |
| `ga-decoys` | the real credential behind two that are not | **`CTAP2_OK`**, and it verifies |

**Every refusal happens before a key is derived.** A device that derived first
and checked afterwards would send the same status byte and would have done the
work an attacker asked for. `check.sh` compares the line numbers and fails if
the check ever moves below the derivation.

```
credential 48 bytes: not ours
credential 48 bytes: not ours
credential 48 bytes: ours, for this relying party
```

`ga-decoys` is why the board names each one: a silent walk past two fakes is
unreadable, and reading it is how you find out it walked rather than derived.

### And the comparison does not return early

```rust
let mut diff = 0u8;
for i in 0..a.len() {
    diff |= a[i] ^ b[i];
}
diff == 0
```

The obvious loop returns as soon as two bytes differ, and **how long it took is
a measurement of how many bytes were right** — which turns forging sixteen bytes
from 2^128 guesses into 16 × 256. On this part a whole assertion costs about
100 ms, so what that leaks would be buried in noise and an attacker would need a
great many tries. **That is an argument for the attack being hard, not for the
code being right**, and the fix costs one `|=`.

`check.sh` reads the loop out of the source with `sed` and fails if a `return`
appears in it. The length check *above* the loop is an early return and a
legitimate one, which is why the check looks at the loop rather than the
function.

## An assertion is not a registration

The authenticator data here is **37 bytes**, not 180: `rpIdHash`, flags,
sign count, and nothing else. The `AT` flag is clear, because attested
credential data belongs to registration and a device that copied its own
`makeCredential` path would attach a public key nobody asked for.

`verify.py` checks the length, the flag and the structure separately, because
that is the mistake this shape invites.

## Checked by somebody else's library, against a key from earlier

```json
"credential_id_echoed": true,   "auth_data_len": 37,   "attested_data": false,
"rp_id_hash_matches": true,     "sign_count": 0,
"signature_valid": true,        "tamper_rejected": true
```

The public key comes from the **registration**, parsed out of that response's
COSE key by the host. The assertion is verified against it by `cryptography` —
not by the `p256` that signed it — and a bit is flipped and the check required
to fail first. If the board had derived a different key the second time, there
is nowhere for that to hide.

## What is not verified here

- **`sign_count` is always zero**, in both directions. A counter that survives a
  reset is a counter that is stored, and this device stores nothing. A relying
  party that enforces monotonicity will notice; that is a limit, not a bug, and
  it is the clearest price of the whole design.
- **The device secret is still a compiled-in test key.** Everything here is
  reproducible by anybody holding the firmware, and that is the
  [identity road](../README.md#the-identity-road)'s question, unanswered.
- **No browser has seen this.** `versions: []` means none would try. What a real
  client does with a device this strict is the road's open question.
- **`MAX_ALLOW` is eight.** A caller offering more has the rest recorded as
  truncated rather than dropped silently.
- **Nothing here is constant-time except the tag comparison**, and no claim is
  made about side channels in the elliptic-curve code.
- **`CTAPHID_KEEPALIVE` is still not implemented.** The `button` build holds a
  transaction open for up to ten seconds and `libfido2` waits; a browser's
  patience is untested.

## Running it

```console
cd experiments/exp172-the-same-key-twice
./check.sh                       # both builds, twenty-seven cases, the round trip
python3 ctaphid.py ga-roundtrip  # register, assert, verify against the first key
python3 ctaphid.py ga-other-rp   # the same credential, somewhere it was not made
```

The build that asks a person — and note it asks **twice**, once to register and
once to assert:

```console
EXP172_UP=button cargo build --release
elf2flash convert -b rp2350 \
  target/thumbv8m.main-none-eabihf/release/exp172-the-same-key-twice \
  target/exp172-button.uf2
yi26 bootsel && yi26 pflash target/exp172-button.uf2
python3 ctaphid.py ga-roundtrip  # hold BOOTSEL down for both
```

## Expected output

Pasted from real runs on a Pico 2, Ubuntu, 2026-08-22. The unattended
transcript is [`capture.txt`](./capture.txt); the one with a finger on the
button is [`capture-button.txt`](./capture-button.txt).

```console
>>> host: case ga-roundtrip
    {"status_name": "CTAP2_OK", "assertion": {
       "credential_id_echoed": true, "auth_data_len": 37, "attested_data": false,
       "rp_id_hash_matches": true, "signature_valid": true, "tamper_rejected": true}}
>>> host: case ga-other-rp
    {"asked_rp": "other.test", "status_name": "CTAP2_ERR_NO_CREDENTIALS"}
>>> host: case ga-decoys
    {"status_name": "CTAP2_OK", "assertion": {"signature_valid": true, ...}}
```

With BOOTSEL held, both halves of the round trip:

```console
[ 3485164 ms]   pressed after 0 ms
[ 3489327 ms]   credential made: authData 180 B (COSE key 77 B), response 277 B
[ 3489387 ms]   derive 44460 us, sign 53786 us, UP bit 1
[ 3489844 ms]     credential 48 bytes: ours, for this relying party
[ 3489904 ms]   waiting for BOOTSEL. Nothing is sent while this runs.
[ 3489964 ms]   pressed after 0 ms
[ 3490123 ms]   assertion: authData 37 B (no attested data), response 187 B
[ 3490183 ms]   derive 44448 us, sign 53685 us, UP bit 1
[ 3490243 ms]   the same key as at registration, and it was never kept.
```

`./check.sh` on the same board:

```console
PASS  the tag comparison has no early return: it accumulates and compares once
PASS  a credential is checked against the relying party it was made for
PASS  the assertion sets only UP: no attested credential data in it
PASS  the assertion's authenticator data is 37 bytes by construction
PASS  a credential that is not ours is refused before anything is derived
PASS  verify.py rejects an assertion that does not verify against the registered key
PASS  verify.py rejects an assertion carrying attested credential data
PASS  verify.py rejects a forged credential that was accepted
PASS  an assertion was made with a key the board had already thrown away
PASS  a forged credential drew a refusal and no derivation at all
PASS  the board says which offered credentials were not its own
PASS  a press is on record: UP=1 with a signature that verifies
```

## Four things to take away

1. **A device that stores nothing can still remember, if the thing it is handed
   back is enough to reconstruct the answer.** The credential ID is not a
   pointer into a table; there is no table.
2. **The tag is what makes it safe, and binding it to the relying party is
   free.** Without it, any forty-eight bytes would be a key. Without the
   binding, one site's credential would sign for another.
3. **Refuse before you derive.** The status byte is the same either way, and the
   difference is whether an attacker got the device to do the work.
4. **An early return in a comparison is a measurement.** Not exploitable here,
   almost certainly — and the fix is one character, so the argument for keeping
   the loop honest never has to be made.

## Next

**A browser.** Everything a client needs now exists: `getInfo`,
`makeCredential`, `getAssertion`, user presence, and self attestation. What
stands between this board and `navigator.credentials` is the honest
`versions: []` from [exp169](../exp169-what-it-says-it-can-do/) — which no
client will act on — and a strict CBOR reader whose refusals no real client has
ever been measured against.

Turning those two into a device a browser registers, and finding out what breaks
when a real implementation meets one this literal, is the next experiment and
the one the whole road was for.
