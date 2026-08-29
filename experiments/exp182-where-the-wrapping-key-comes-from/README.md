# exp182 — where the wrapping key comes from

[exp171](../exp171-a-credential-nobody-asked-for/) through
[exp174](../exp174-a-deadline-nobody-mentioned/) built a security key whose
device secret was a compiled-in constant, and said so on every line of their
logs. [exp175](../exp175-the-secret-is-the-file/) then showed what that costs:
`forge.py` finds those thirty-two bytes in the `.uf2` and mints a working
WebAuthn assertion with no board involved. **Possession of the image was
possession of the identity.**

This is the same authenticator with the secret coming from somewhere else:
[exp181](../exp181-a-key-that-is-written-nowhere/)'s key, reconstructed at boot
from SRAM bank 8, whose startup pattern
[exp179](../exp179-what-survives-a-reset/) measured surviving power-on.

> **Verified on hardware, 2026-08-23.** `fido2-cred` made a credential,
> verified its self attestation, and `fido2-assert` used it — a full round trip
> on somebody else's client. And **exp175's forgery, unchanged, finds nothing**
> in this image while still minting an assertion from exp174's.

## The test is somebody else's attack failing

```console
$ python3 ../exp175-the-secret-is-the-file/forge.py target/exp182-button.uf2 example.test
the test-key secret is not in target/exp182-button.uf2 — is this an exp171+ image?   (exit 1)

$ python3 ../exp175-the-secret-is-the-file/forge.py ../exp174-.../target/exp174.uf2 example.test
  "signature": "MEYCIQCRtDRdqSvR15CkcDR169YgWmlNRQr_yQu2ZcraDXVeXw...",
  "up_bit_claimed": true
```

Same script, same attack, two images. One of them is an identity you can carry
away in a file; the other is not. The control matters as much as the result:
without exp174's line, "found nothing" would be indistinguishable from a script
that no longer works.

**What this does not prove** is that the key is unpredictable. It proves the key
is not *in the image*, which is the specific thing exp175 demonstrated and the
specific thing this rung was asked for.

## The arithmetic moved out, and it has not been on a board since

> **Added and verified on hardware, 2026-08-29.** The strongest form the proof
> could take: the moved arithmetic reconstructed **the key the unmoved
> arithmetic enrolled six days earlier**, from a record written to flash on
> 2026-08-23 and never rewritten. Record layout, helper bit order, majority vote
> and key hash are byte-for-byte what they replaced, and nothing had to be
> re-enrolled to prove it.
>
> ```text
> device secret: reconstructed from SRAM — the key came back
>   bank 8 came up 51.1% one-bits
>   enrolled at 51.1%, 486 of 7936 cells changed since
> ```
>
> 486 of 7,936 is 6.12%, against exp181's 494 and 6.22% on the same board. The
> two guards held on the way through: the boot straight after `yi26 flash` said
> `UNPROVISIONED — the key did NOT come back`, because flashing zeroes the SRAM,
> and the key came back on the boot after the power was away. `./check.sh`
> passes all forty of its checks with the board running it.

`puf_helper`, `puf_reconstruct`, `puf_uniformity`, `puf_hash`, the record layout
and the constants they share now live in
[`crates/fuzzy-commitment`](../../crates/fuzzy-commitment/).
[exp189](../exp189-the-same-salt-twice/) wants the same key, and the choice was
between copying a hundred lines into it — the drift this repository has a whole
convention against — and lifting them where both can reach.

**What stayed here is the half that is hardware**: the bank 8 address, where the
record lives in flash, the volatile reads that fill the window, and the flash
write that stores a record. A crate that read SRAM could not be tested anywhere
but on a board; this one is handed a slice, so **eight tests run on a host with
no board at all** — including the two that matter most, that fifteen flips of
thirty-one still vote the right way and sixteen do not, and that a zeroed window
makes the helper data *become* the key, which is exp179's trap stated as an
assertion rather than as a paragraph.

That power cycle was the whole test, and it is the reason this section is short.
A refactor that keeps a green `check.sh` proves the host half; a refactor that
reconstructs a key enrolled by the code it replaced proves the rest, and there
was no way to fake it — the record in flash was written by the old build.

## What changed in the firmware

`DEVICE_SECRET` was a `const [u8; 32]` used by exactly two functions. Both now
take the secret as an argument, threaded from a value reconstructed at boot —
not a global, because a global is a place it can be reached from anywhere and
this repository's own `check.sh` should be able to see that it is not.

Everything else is exp174 unchanged: the same CTAPHID, the same CBOR, the same
`CTAPHID_KEEPALIVE` behaviour that experiment was named for.

## Three states, and a light that says which

A board straight from `yi26 flash` **cannot make a credential**. exp179 measured
that flashing zeroes SRAM, so there is nothing to reconstruct from until the
power has been away once. That is not a defect of this build; it is what a key
that lives in the chip costs operationally, and it happens after **every**
firmware update.

| LED | what it means | what to do |
| --- | --- | --- |
| one short flash a second | running, nothing wanted | nothing |
| **solid on** | a request is waiting for a user | **hold BOOTSEL now** |
| **two quick flashes, then a pause** | no secret | **unplug it and plug it back in** |

**The LED is not decoration here, and this experiment learned that the
expensive way.** Its first round trip printed *hold BOOTSEL* to a terminal and
timed out, because the board was being driven from another machine where a
script's stdout — and the firmware's log, which is also read on the host —
reaches nobody. `AGENTS.md` already says *the LED is the debug channel, so
design it before you need it*, and
[exp180](../exp180-the-silicon-or-the-room/) had used three LED states for
exactly this a few hours earlier. This one went back to words and paid a round
trip to find out.

## Two refusals that must not share a number

An unprovisioned board answers `0xF0`, a vendor status, and **not**
`CTAP2_ERR_OPERATION_DENIED` — which is what this same firmware returns when
nobody presses the button. Those are different facts: *come back after a power
cycle* and *you were not there*.
[exp173](../exp173-a-client-that-is-not-ours/) is an entire experiment about
what one shared number costs, and the first version of this firmware made the
collision anyway.

Both readings were measured rather than argued:

```text
  0x27 CTAP2_ERR_OPERATION_DENIED -> fido2-cred: FIDO_ERR_OPERATION_DENIED
  0xF0 vendor                     -> fido2-cred: FIDO_ERR_UNKNOWN
```

Neither is clean, because **CTAP 2.1 has no status for "I have no key material
yet"**. This build takes a number that means *ask* over a number that means
something else, and the LED and the log answer when a client asks.

## The error rate, four times

Every boot reports how far the window has drifted from the enrolment. Across
exp181 and this experiment, on the same board:

```text
  6.22%   exp181, the enrolment's first reconstruction
  6.15%   exp182, first power cycle
  6.44%   exp182, second
  6.07%   exp182, third
```

Sixteen of thirty-one cells would have to flip to break a single key bit; about
two do. And the failure mode is visible in the same numbers: on the boot after a
flash the window is zeros, **43%** of the cells "changed", the hash does not
match, and the device refuses.

## What this does not establish

- **Not uniqueness.** exp181 could not show the key differs between chips and
  neither can this. A PUF that is stable but not unique is a device that
  reliably reconstructs *somebody else's* identity, and for an authenticator
  that is the sharpest form of the caveat.
- **Not secrecy in use.**
  [exp163](../exp163-how-long-is-a-secret-in-the-open/) measured how long a key
  sits readable in SRAM. Every word of it applies: this changes where the key
  comes from, not whether it can be read while it is being used.
- **Not attestation.** The AAGUID is still sixteen zero bytes and there is still
  no certificate, which is what [exp176](../exp176-the-same-question-of-two-devices/)
  called the one difference that is not code.
- **Not a security key to use.** It is a security key to understand.

## Running it

```console
EXP182_UP=button EXP182_TIMEOUT_MS=60000 cargo build --release
elf2flash convert -b rp2350 target/thumbv8m.main-none-eabihf/release/exp182-where-the-wrapping-key-comes-from target/exp182-button.uf2
yi26 flash target/exp182-button.uf2
```

Then **unplug it and plug it back in** — the LED will be double-flashing until
you do. After that:

```console
./roundtrip.sh          # hold BOOTSEL whenever the LED goes solid
./check.sh
python3 ../exp175-the-secret-is-the-file/forge.py target/exp182-button.uf2 example.test
```

The enrolment lives at 3 MiB into flash and survives reflashing, so the board
keeps its identity across firmware changes — which is the whole point, and is
demonstrated by this experiment reconstructing the key **exp181** enrolled.

## Expected output

```text
PASS  python3 present
PASS  fido2-token present (the host's own tool)
PASS  firmware compiles (295308 byte ELF)
PASS  there is no compiled-in device secret left in the source
PASS  both key-using functions take the secret as an argument, not from a global
PASS  an unprovisioned board has its own status, not the one that means no press
PASS  and both credential commands refuse with it (makeCredential, getAssertion)
PASS  the LED has a state for 'press now' and one for 'power cycle me'
PASS  and it is set where the presence window opens, not at the call sites
PASS  enrolment refuses a cleared window (exp179's 0.00% after a flash)
PASS  exp175's forgery, run live, finds no secret in this image
      ruling on capture-unprovisioned.txt
PASS  the transcript says what bank 8 held
PASS  and how far that was from the enrolment
PASS  the window read 0.0% — cleared, which is what flashing leaves (exp179)
PASS  3419 of 7936 cells apart, a 43% error rate no 31-fold repetition can carry
PASS  so the device refused rather than signing with the majority vote's output
PASS  and a real client saw the refusal, rather than a credential nobody could check
PASS  nothing in this transcript claims the key came back
PASS  and the firmware says, in its own log, that the image carries no key
      ruling on capture-provisioned.txt
PASS  the transcript says what bank 8 held
PASS  and how far that was from the enrolment
PASS  the window read 51.1% — a power-on reading
PASS  the key came back
PASS  482 of 7936 cells had changed, a 6.07% error rate, well inside what the code carries
PASS  and the enrolment it was measured against was itself a power-on reading (51.1%)
PASS  nothing in this transcript claims the board is unprovisioned
PASS  and the firmware says, in its own log, that the image carries no key
      ruling on capture-roundtrip.txt
PASS  fido2-cred made a credential
PASS  fido2-cred verified the self attestation
PASS  fido2-assert used the credential
PASS  and the assertion verified against the key the credential handed over
PASS  nothing in the round trip was refused
      ruling on capture-forge.txt
PASS  exp175's forgery finds nothing in this experiment's image
PASS  and mints a working assertion from exp174's, which is the control that says the attack still works where the secret is in the file
PASS  including a user-presence bit it simply asserts, with no board present
SKIP  the board is not running exp182; the checked-in transcripts stand
PASS  the README names exp175
PASS  the README names exp179
PASS  the README names exp181
PASS  the README names exp163
```

Four transcripts are checked in beside it: the refusal, the reconstruction, the
round trip, and the forgery run against both images.
