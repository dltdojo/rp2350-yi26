# exp175 — the secret is the file

Every experiment from [exp171](../exp171-a-credential-nobody-asked-for/) on has
said, in its own README, that its key is a **test key** compiled into the
firmware. This is the experiment that measures what that sentence costs.

It has no firmware of its own. Its subject is [exp174](../exp174-a-deadline-nobody-mentioned/)'s
image, and its claim is one line:

> **This board is not the secret. The `.uf2` file is — and anyone who has the
> file can be the device, without ever touching the board.**

The eighth on the [authenticator road](../README.md#the-authenticator-road),
and the first that attacks the road's own product.

> **Verified on host and hardware, 2026-08-23.** `forge.py` mints a working WebAuthn
> assertion from the firmware image alone, and `verify.py` confirms it three
> ways — the signature is real, the device's own acceptance check would take
> the credential, and the public key is the one the device derives. No board is
> involved in any of it. Separately, `survive.sh` showed on hardware that a
> credential registered before the board was reflashed to another firmware and
> back still logs in — the secret is in the image, not the board. See
> [Expected output](#expected-output).

## Why a compiled-in key is a forgeable key

exp171 builds every credential out of one 32-byte constant:

```text
credential id = nonce(32) || HMAC(secret, "id"  || nonce || rpIdHash)[..16]
private key   = HMAC(secret, "key" || counter || nonce || rpIdHash), rejected
                until it is a valid P-256 scalar
```

There is no `nonce` a defender keeps and no scalar a chip holds. Given the
secret, the whole of it is a pure function of public inputs. So the attack is
not extraction — there is nothing to extract. It is **recomputation**:

1. `unpack.py` reassembles the flash image the `.uf2` describes and finds the
   secret at a known address;
2. `forge.py` mints a credential id whose tag is valid under that secret,
   derives its private key, and signs an assertion with the user-presence bit
   set — because a forger decides what the flags say;
3. `verify.py`, re-deriving everything independently, confirms the signature
   verifies, the tag would pass the device's own `credential_is_ours`, and the
   public key matches the one the device would derive.

The private key was never *in* the board. It was never anywhere. It is what the
secret computes, and the secret ships in the image.

## The .uf2 does not hide what a grep says it hides

A UF2 is 512-byte blocks, each carrying 256 bytes of payload behind a header.
A plain `grep` for a 32-byte secret can miss it even when it is right there,
because a block boundary can fall in the middle of the string. On the exp174
image this experiment was verified against, **the boundary does split it and the
raw grep finds nothing** — while `unpack.py`, reassembling the payload the way
the bootrom does, finds it at `0x10010bf8`. A student who greps the file, sees
nothing, and concludes the key is hidden has learned the exact opposite of the
truth. (On a different build the boundary might spare the string and the grep
succeed; that it ever works is luck, which is why `check.sh` reports whichever
way it fell rather than asserting one.)

There is a second false comfort the README states rather than demonstrates:
**erased flash is not necessarily gone.** [exp137](../exp137-the-volume-that-changes/)
is about what a host's storage stack really does with a wipe; the same caution
applies to a chip's flash, and "I reflashed it" is not "the bytes are gone".

## The two hardware facts behind it

`drive.sh` shows both, and both need a person:

- **A credential outlives the firmware.** Register a credential, reflash the
  board to a *different* experiment — wiping the key entirely — then reflash
  exp174 and log in with the same credential. It works, because the credential
  was never in the board's state; the image put the secret back. `survive.sh`
  does this unattended with the `UP=none` build (the claim is about storage, not
  presence); `drive.sh` does the pressed `button` version.

- **The same secret reads off a live board.** [exp141](../exp141-two-doors-into-the-bootrom/)'s
  PICOBOOT port, which a browser drives, dumps flash, and the secret sits at the
  address `forge.py` used. This half points at exp141 rather than repeating it:
  reading flash from a browser is exp141's subject.

Neither is required to prove the claim — the offline forgery already does — but
each shows a different attacker: A is *someone with the file*, B is *someone with
the board*.

## What would close it, and why this project does not

A key whose secret an image can carry is a key an image can forge. The fix is a
secret the image **cannot** carry: derived on-device from something the firmware
does not contain.

Two real answers exist, and both are named here so the gap is not left blank:

- The [identity road](../README.md#the-identity-road) — a per-chip value the
  firmware measures rather than ships. Unbuilt.
- The RP2350's own **Secure Boot + Secure Lock**: a master key in one-time
  programmable memory, unreadable outside secure code, used to encrypt
  everything in flash. This is a real defence against exactly the flash dump in
  demonstration B.

**This project uses neither, on purpose.** Secure Lock burns OTP — irreversible,
and a fuse this repository's roads deliberately never touch. So exp175's finding
is not "we did it wrong"; it is "here is precisely the boundary the test key
draws, and here is the mechanism that would move it, which is out of scope."
That mechanism is what [exp177](../README.md#the-authenticator-road) will look
at in a firmware — pico-fido — that does turn it on.

## How this compares to a real key

A production key derives or stores its secret so that neither the firmware image
nor a flash dump yields it: a dedicated secure element, or a chip-unique key
behind OTP. The distance from exp174 to that is not CTAP features — it is this
one property, and exp175 is the experiment that measures it as a demonstration
rather than asserting it as a caveat. The later rungs
([exp176](../README.md#the-authenticator-road) against a commercial key,
[exp177](../README.md#the-authenticator-road) against pico-fido on the same
chip) put numbers on the rest of the distance.

## Running it

```console
./check.sh          # the offline forgery and its mutations — no board
./survive.sh        # step A, unattended: a credential outlives a reflash
./drive.sh          # the same with the pressed button build, plus the exp141 pointer
```

`check.sh` builds exp174's image if it is not already there, lifts the secret,
forges an assertion, verifies it, and then tampers with the forgery four ways
and requires each to be caught — exp159's rule, applied to a conclusion.

## The key is still a test key

`forge.py` forges against `not a secret. this is a test key`, the 32 bytes
exp171 prints in its own README. Forging against a value the repository
publishes is the whole point: it shows a **compiled-in** secret is a forgeable
one. Nothing here works against a key whose secret the image does not contain,
which is exactly the key the identity road is for.

## Expected output

See [capture.txt](./capture.txt), and `forged-example.json` for a worked
forgery `verify.py` re-checks from the image.
