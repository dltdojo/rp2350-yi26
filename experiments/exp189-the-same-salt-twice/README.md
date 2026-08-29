# exp189 — the same salt twice

[exp172](../exp172-the-same-key-twice/) got a private key back from forty-eight
bytes somebody handed over, and signed with it. This one gets a **symmetric
key** back — and nothing checks it, because there is nothing to check.

**A signature is something a third party verifies. A key is something that
either opens the file or does not.** That difference is the experiment.

On the [authenticator road](../README.md#the-authenticator-road), and the first
rung whose product is not evidence.

> **Verified on hardware, 2026-08-29.** The same salt, twice, minutes apart,
> gave **the same thirty-two bytes bit for bit**. A different salt moved 125 of
> 256 bits and a different credential 110; an ordinary assertion with no
> extension still works; and with the board left alone for four attempts, **no
> key came out** — `FIDO_ERR_OPERATION_DENIED`, which is not a code the PIN
> family uses. See [Expected output](#expected-output).

## Why this rung exists at all

[exp176](../exp176-the-same-question-of-two-devices/) asked the same question of
this board and a Yubico key and sorted every difference by kind. Ten of the
fourteen were called *code the board could write*, and `hmac-secret` was on that
list. [exp178](../exp178-the-shape-of-the-contract/) then closed it on the host,
inside somebody else's engine, and reported it closed.

It is not written here. `grep extensions` over
[exp188's firmware](../exp188-the-passkey-in-the-pocket/src/main.rs) returns
nothing.

And it is the one extension with a use outside a browser: `hmac-secret` is what
`systemd-cryptenroll --fido2-device`, `fido2luks` and `age-plugin-fido2-hmac`
all stand on. Every rung before this produced a login. This one produces a key
somebody can encrypt a file with, which is what exp190 is for.

## A signature is not a key, and that changes what can be asserted

Everything this road has produced so far was checkable by somebody who was not
the board. exp171's attestation, exp172's assertion, exp173's `fido2-cred -V` —
each one is a claim a third party can grade.

Thirty-two bytes are thirty-two bytes. No library will tell you they are the
right ones. Their correctness is observable **only as reproducibility**, so
every case below is a comparison rather than a validation, and the experiment is
built out of pairs:

| case | asks for | must come back |
|---|---|---|
| `ga-salt1` | credential A, salt `S1` | 32 bytes, recorded |
| `ga-salt1-again` | credential A, salt `S1`, minutes later | **the same 32 bytes, bit for bit** |
| `ga-salt2` | credential A, salt `S2` | **different bytes** — Hamming distance reported, not asserted to be exactly 128 |
| `ga-credB-salt1` | credential B, salt `S1` | **different bytes** — the key is bound to the credential |
| `ga-plain` | credential A, no extension | an ordinary assertion, unchanged from exp173 |

Seven presses, and [`./roundtrip.sh`](./roundtrip.sh) drives them. The case that
matters as much as any of these — **nobody presses, and nothing comes out** — is
not in that list and not in that script, for the reason below.

## The LED is the only interface, so it may only mean one thing

A person at the board cannot see this script's prompts. The board is driven
remotely; stdout reaches a terminal nobody is sitting at, which is exactly what
[exp182](../exp182-where-the-wrapping-key-comes-from/) had to learn when its
first round trip timed out with its instructions printed to nobody. **The LED
going solid is the whole interface.**

The no-press case ran the same firmware path as every other case, so it lit the
same light — and the one press that must never happen was being requested by the
only channel the person had. **A key came out twice**, and the transcript could
not say whether the device had lied or a person had answered a light that meant
what it always means.

Two things came out of that and both are in the experiment now:

- **It is a separate script, and it needs nobody.**
  [`./nopress.sh`](./nopress.sh) runs on credential A out of `work/` and is
  meant to be started and walked away from. `./roundtrip.sh` now has exactly
  seven solid LEDs and every one of them means press, with no exception to
  remember. An instruction that says *do not press* is an instruction that
  should not have been needed.
- **The board says when its pad reads low.** `presence: BOOTSEL read low at
  N ms`, filtered by the board's own clock so a press from earlier in the boot
  cannot be mistaken for this one — the log is a ring and it replays. If a key
  ever does come out, that line is the difference between *the device set the
  bit by itself* and *somebody pressed*, and `verify.py` says two different
  sentences accordingly. `check.sh` builds both records and requires it to.

**Eighteen attempts with nobody in the room refused every one**, at both the
10 ms poll the engine was inherited with and the 20 ms
[`crates/bootsel`](../../crates/bootsel/) asks for in its own documentation. The
poll interval is a build input now — `EXP189_PRESENCE_POLL_MS`, default 20,
matching [exp174](../exp174-a-deadline-nobody-mentioned/) — and the A/B found no
difference between the two, which is written here rather than implied by the
change.

[exp173](../exp173-a-client-that-is-not-ours/)'s lesson and exp182's still apply
to the refusal itself: one number meaning two things cost this road an entire
experiment the first time and a second status code the second time.

## Where the thirty-two bytes come from

```text
CredRandom = HMAC(device_secret, "credrandom-noUV" ‖ credId)
output     = HMAC-SHA256(CredRandom, salt)
```

**Nothing is stored**, which is exp172's rule arriving in a new place. The
specification has the authenticator generate a per-credential random at
registration and keep it; this board recomputes it from the credential ID the
client hands back, so there is no table to fill, no table to leak, and no table
to run out of.

A credential this board did not make has no `CredRandom` — but that is not what
stops it. exp172's tag check refuses it **before** any of this runs, and for the
same reason it always did: the credential ID carries `HMAC(secret, "id" ‖ nonce
‖ rpIdHash)`, so a credential collected from one relying party computes nothing
at another.

**The specification defines two of these** — `CredRandomWithUV` and
`CredRandomWithoutUV` — and this build computes only the second, because it has
no user verification. `getInfo` must not claim otherwise:
[exp169](../exp169-what-it-says-it-can-do/) is the rung about a device that
announces a capability it does not have.

## The only new cryptography is one HMAC

The extension arrives inside `getAssertion` as a map the client encrypted, and
every part of the tunnel it uses was built by
[exp185](../exp185-a-channel-before-a-secret/):

```text
"hmac-secret": {
  0x01: keyAgreement   COSE key — the platform's ephemeral P-256 public key
  0x02: saltEnc        AES-256-CBC(sharedSecret, salt), zero IV
  0x03: saltAuth       HMAC-SHA256(sharedSecret, saltEnc)[..16]
}
```

`sharedSecret` is `SHA-256(ECDH_x)`, which exp185 already computes; the reply
goes back encrypted under the same key. So the firmware change is a CBOR branch,
a verification, one `HMAC-SHA256`, and an encryption — and if any of that is
new, exp185 is the experiment to read rather than this one.

## The press gates the arithmetic, not the transmission

[exp171](../exp171-a-credential-nobody-asked-for/) wrote down that the bit
saying a person was present is the device's own word and nothing in the protocol
checks it. Here the consequence is sharper, because the client is not asking for
a bit — it is asking for a key.

So the wait for BOOTSEL happens **before** the HMAC, not before the send. A
build that computes the key and then waits has already made the secret exist,
and every bug in the path after that point is a bug that leaks one. `check.sh`
reads the order out of the source and fails if it inverts.

`CTAPHID_KEEPALIVE` goes out while it waits, for
[exp174](../exp174-a-deadline-nobody-mentioned/)'s reason: below the ceiling it
changes nothing, and it is what makes this keep working when a person is slow.

## Two arms, and somebody else's attack

Built twice from one source, because a half of a comparison is not a comparison:

```console
EXP189_KEY=constant cargo build --release    # exp171's compiled-in test key
EXP189_KEY=bank8    cargo build --release    # exp181's key, reconstructed from SRAM
```

[exp175](../exp175-the-secret-is-the-file/)'s `forge.py` is then pointed at both
images. It must succeed against `constant` — the control that says the script
still works — and find nothing in `bank8`. This is exactly
[exp182](../exp182-where-the-wrapping-key-comes-from/)'s method, applied to a key
that decrypts instead of a key that signs.

**And that is the sharper case.** A forged signature is caught by whoever
verifies it. A forged decryption key is caught by nobody: it opens the file, and
the file does not know who asked.

**Verified, and it needed no board:**

| image | `forge.py` | *not a secret. this is a test key* |
|---|---|---|
| `exp189.uf2` | **forged an assertion** | in the bytes |
| `exp189-bank8.uf2` | **found nothing** | absent |

`check.sh` asserts both halves of that table by reading the images, so the
comparison cannot quietly stop being one.

### The first bank8 arm was forgeable, and that is worth writing down

It reconstructed its key from SRAM exactly as designed, used it for everything,
and `forge.py` minted an assertion from its image anyway — because
`DEVICE_SECRET` was still *compiled in*, sitting unused in the binary. **A secret
in a file is a secret anybody with the file has, whether or not the firmware
reaches for it.** The arm is now built with `#[cfg(not(bank8))]` on the constant
itself, and `build.rs` emits that cfg rather than leaving it to a `const bool` a
linker is free to keep.

### What it cost to wire, in two silent deaths

Both were the same failure and it is the one this road keeps meeting: **a
firmware that dies before its USB stack is serving is a board that has left the
bus**, indistinguishable from a bad cable and recoverable only by hand.

- **An interface nobody services takes the whole device down.** The first
  version did not spawn the CTAPHID task when there was no key — but the HID
  interface is in the descriptor either way, so the board listed as a security
  key, answered nothing, and then dropped off USB entirely. It now always serves
  and refuses what it cannot key, with `CTAP2_ERR_NO_SECRET` of its own, for
  [exp173](../exp173-a-client-that-is-not-ours/)'s reason.
- **Zero is not a valid P-256 scalar.** `secret_bytes()` returns thirty-two zero
  bytes on an unprovisioned board, and `SecretKey::from_slice(...).unwrap()` on
  those is a panic — on every boot of the `bank8` arm before its first cable
  pull. `panic-halt` made it silent. This firmware now has a
  `#[panic_handler]` that names the file and line, and `check.sh` fails if
  either the silent handler or that `.unwrap()` comes back.

## The ready-made version, as the control

`age` plus [`age-plugin-fido2-hmac`](https://github.com/olastor/age-plugin-fido2-hmac)
already does what exp190 is going to build by hand: it encrypts a file to a
FIDO2 authenticator's `hmac-secret` and will not open it without the token.

It is here for [exp178](../exp178-the-shape-of-the-contract/)'s reason. This
repository hand-rolled FAT12, SCSI, Bulk-Only Transport, DHCP and its own CBOR —
and exp178 priced OpenSK's engine at 121,184 bytes of flash *before* anybody
argued about whether to use it. Hand-rolling after measuring the alternative is
a decision; hand-rolling instead of measuring it is a reflex. So the ready-made
tool runs first, and exp190 is written knowing what it cost to not use it.

**What it has to show is a stronger sentence than the rest of this experiment
can produce.** `fido2-assert` printing thirty-two bytes says something came
back. `age` encrypting a file, the board being asked for a press, and the
plaintext coming back byte-identical says a tool that does not know this board
exists opened a file with its key.

**And a refusal is the finding, not the failure.** This build has no PIN and no
resident credentials, by choice — one press of BOOTSEL and nothing else. If the
plugin demands either, then what it demands and in what words is what gets
recorded, exactly as [exp169](../exp169-what-it-says-it-can-do/) recorded a tool
refusing an honest `versions: []` and [exp174](../exp174-a-deadline-nobody-mentioned/)
recorded a browser giving up on a device that was working. `check.sh` never
gates on the plugin succeeding, and the experiment does not grow a PIN to make
somebody else's tool happy.

### What reading the tools actually said

[`setup.sh`](./setup.sh) follows [exp177](../exp177-the-same-chip-somebody-elses-decisions/)'s
rule for somebody else's software — one released binary per tool, fetched by
URL, checked against a SHA-256 written into the script, kept in a git-ignored
directory, never vendored, and named by version here. That rule is what survives
the objection a network-service client does not: a pinned binary is a dated
observation, and no pin fixes a tool whose behaviour lives on somebody's server.

**Measured, 2026-08-29:** `age` **v1.3.1** and `age-plugin-fido2-hmac`
**v0.5.0**, both `linux-amd64`, both fetched and hashed by `setup.sh`. Both run
on this host — the plugin prints its magic identity with no token attached at
all — so what follows is read out of `--help` rather than assumed:

| what the tool says | what it means for exp190 |
|---|---|
| `-g` generates credentials **interactively** | the control has a prompt sequence, so it costs a person in a way nothing else in exp189 does |
| `-s` is symmetric, and *"the token must be present for every operation"* | the strict mode. Without it the plugin derives an X25519 keypair, so **encryption does not need the board and only decryption does** — which is the shape exp190's vault actually wants |
| `age -d -j fido2-hmac secret.enc` | decryption with **no identity file at all**, which is one fewer thing for a wrapper to carry |
| `FIDO2_TOKEN` forces a device path, and its own help warns `/dev/hid*` is ephemeral | naming the board is the plugin's problem too, not just this repository's |

**What is still unread is the prompt sequence behind `-g`**, and it stays unread
until there is a board with `hmac-secret` to point it at. A driver written
against prompts nobody has seen is the fabrication this repository's method
exists to stop, and it is the same rule that made `check.sh` fail honestly
rather than skip.

**The base this rung stands on was checked before anything was built on it**,
because the road's own history says the failure mode here is silence. Four
firmwares, one question, `fido2-token -I` — somebody else's client, no button
needed:

| firmware | `caps` | what libfido2 got |
|---|---|---|
| [exp183](../exp183-the-contract-and-the-lock/) as shipped | `0x08` | stops at the byte and **never asks** |
| exp183 with the byte corrected | `0x0c` | **no answer in two minutes**, and the board then needed a hand on BOOTSEL |
| [exp174](../exp174-a-deadline-nobody-mentioned/) | `0x0c` | full `getInfo` in **0.82 s** |
| [exp188](../exp188-the-passkey-in-the-pocket/) | `0x0c` | full `getInfo` in **0.12 s** — `FIDO_2_1`, `rk`, `uv`, `credMgmt`, `pinUvAuthToken` |

**exp189 is built on exp188, and exp188 survives the conversation.** That is
the line that mattered, and it is measured rather than assumed.

exp183's `CTAPHID_INIT` answers `0x08` — `CAPABILITY_NMSG` — under a comment
that says `CBOR`. The CBOR bit is `0x04`, and every other rung from
[exp169](../exp169-what-it-says-it-can-do/) to exp188 sends `0x04 | 0x08`. The
one other experiment that sends `0x08` alone is
[exp168](../exp168-a-security-key-that-knows-nothing/), which does it **on
purpose**, having no CBOR at all — so exp183 landed on the "I know nothing"
value while implementing a full authenticator. Its own CBOR works: this
repository's client gets `CTAP2_OK` and `versions: ["FIDO_2_0"]` out of it. The
byte is what stopped anybody else asking, and correcting it found something
worse behind it. That belongs to exp183 and is written up there.

## What this does not establish

- **Uniqueness.** [exp181](../exp181-a-key-that-is-written-nowhere/) could not
  show it and neither can this. A PUF that is stable but not unique is a chip
  reliably reconstructing somebody else's key — and where exp182 meant somebody
  else's *identity*, here it means somebody else's *decryption key*.
- **That the key is hidden while in use.**
  [exp163](../exp163-how-long-is-a-secret-in-the-open/) applies unchanged, at
  both ends of the cable.
- **A browser.** WebAuthn's `prf` extension is this same primitive with a
  different face, and exp174 proved a browser talks to this board, but nothing
  here tests it.
- **A PIN.** This build has no user verification at all, by choice: one press of
  BOOTSEL, which is what [exp186](../exp186-the-number-behind-the-finger/)'s
  state machine is deliberately not being asked for here.
- Nothing about whether this is a security key to use. It is a security key to
  understand.

## Three things the inherited code had wrong, and why nobody had noticed

The firmware is [exp188](../exp188-the-passkey-in-the-pocket/)'s with
`hmac-secret` added. Adding it found two numbering mistakes in the request
parsers, and both have the same shape as
[exp183](../exp183-the-contract-and-the-lock/)'s capability byte: **a value that
nothing had ever exercised.**

| where | was | is | what it did |
|---|---|---|---|
| `makeCredential` key `0x06` | read as `pinUvAuthParam` | `extensions` | `0x06` is pinUvAuthParam in **getAssertion**, not here. An extension map is not a byte string, so **every `makeCredential` carrying any extension was refused with `CTAP2_ERR_INVALID_CBOR`** |
| `getAssertion` key `0x07` | read as `pinUvAuthParam` | `pinUvAuthProtocol` | a uint read as a byte string, so a request that named its PIN protocol was refused the same way |

| `crates/cbor`'s `skip` | refused any map key that was not a uint or text | negative keys are legal | a COSE key is `{1, 3, -1, -2, -3}`, it is *skipped* rather than read in a `getAssertion`, and the `-1` made the whole request `CTAP2_ERR_INVALID_CBOR` |

That third one is [exp170](../exp170-a-map-somebody-else-wrote/)'s own open
question, answered. Its README says the reader refuses shapes that are valid and
not canonical, and that **whether a real client sends something this strict
reader rejects is untested**. It does — every `hmac-secret` request `libfido2`
builds contains one — and
[`crates/cbor`](../../crates/cbor/) now knows the specification's order for
negative keys, with three tests covering the shape that was refused and the two
orderings that must still be.

Neither of the first two could be found by a client that never sends the field. exp188's own
probe does not, `libfido2` only sends `extensions` when asked to, and nothing
had asked — which is [exp173](../exp173-a-client-that-is-not-ours/)'s subject
for the second time in one afternoon.

**The first one is now proven fixed from the outside**, and it cost nobody a
press: `fido2-cred -M -h` sends an `hmac-secret` extension map, and the board's
log shows the request parsed through to `makeCredential: rp="example.test"`
instead of dying at the map header.

Both are still present in exp188. Correcting them there is a change to a
verified experiment and belongs to a round of its own.

## What the second arm still owes

The arithmetic is [`crates/fuzzy-commitment`](../../crates/fuzzy-commitment/) —
lifted out of exp182's 2,377-line `main.rs` on 2026-08-29 and verified there in
the strongest form available: the moved code reconstructed **the key the unmoved
code enrolled six days earlier**. What is here is the hardware half — bank 8's
address, the record at 3 MiB, and the reads that touch them — and both
experiments share those two numbers, so a record written by either is readable
by the other.

**What has not run is the arm on silicon.** Its finding is verified and needed no
board; whether this firmware reconstructs and then produces the same thirty-two
bytes is a question only a board that has had its power away can answer.
[`./bank8.sh`](./bank8.sh) is that run in one command, and it **waits for** the
cable pull rather than asking for it at a moment nobody is standing there.

Two costs come with the arm and both are exp182's, measured rather than guessed.
A board straight from `yi26 flash` **can do nothing** until the power has been
away once, because flashing zeroes the SRAM the key comes from — the first boot
is supposed to say `UNPROVISIONED`, and a run where it does not is a run where
something else is wrong. And **uniqueness is not shown**, which for a key that
decrypts is the sharpest form of exp181's caveat: a PUF that is stable but not
unique is a chip reliably reconstructing somebody else's key.

## Running it

Two scripts, and the split is the point: one costs a person seven presses, the
other costs nobody anything.

```console
./setup.sh --pin v1.3.1 v0.5.0   # once, and only for the control
./setup.sh                       # verifies and unpacks what is pinned

EXP189_KEY=constant cargo build --release
elf2flash convert -b rp2350 target/thumbv8m.main-none-eabihf/release/exp189-the-same-salt-twice target/exp189.uf2

./roundtrip.sh     # Needs 2 — seven solid LEDs, press at every one
./nopress.sh 4     # Needs 1 — start it and walk away
./check.sh

EXP189_KEY=bank8 cargo build --release
elf2flash convert -b rp2350 target/thumbv8m.main-none-eabihf/release/exp189-the-same-salt-twice target/exp189-bank8.uf2
./bank8.sh         # Needs 2 — one cable pull, and it waits for it
python3 ../exp175-the-secret-is-the-file/forge.py --hmac-secret target/exp189-constant.uf2 example.test
```

`roundtrip.sh` puts `target/exp189.uf2` back before it starts, so the boot
banner naming the arm belongs to the run and the transcript describes the image
in `target/` rather than whatever was resident. It costs nobody anything: from
[exp105](../exp105-usb-reboot/) on, the 1200-baud touch reboots the board from
the host. It also leaves credential A in `work/`, which is what lets
`nopress.sh` need no press at all.

A missed press costs one extra window rather than the whole run — the retry
fires only on `FIDO_ERR_OPERATION_DENIED`, which is the refusal that means
nobody was there. Any other refusal is the subject failing and is not retried.

The client is `libfido2`'s own, on purpose: the point of this rung is that
somebody else's tool asks for the key and accepts what comes back.

```console
fido2-cred  -M -h -i cred_param  /dev/hidraw5   # hmac-secret at registration
fido2-assert -G -h -i assert_param /dev/hidraw5 # line 4 in is the salt, the last line out is the key
```

exp190 uses this repository's own CTAP client instead, and the reason is written
there.

## Expected output

`./roundtrip.sh`, seven presses:

```text
>>> putting target/exp189.uf2 back, so the boot banner is this run's
>>> seven solid-LED windows follow. Press BOOTSEL at every one of them.
    [    3037 ms]   key source: constant (secret is in the image: true)
    [    3037 ms]   hmac-secret: HMAC(CredRandom, salt); CredRandom = HMAC(secret, domain || credId)
    [    3037 ms]   the press gates the arithmetic: no salt is ever hashed before BOOTSEL
>>> credA: fido2-cred -M -h — PRESS BOOTSEL
    made, self attestation verified, hmac-secret bit signed
>>> credB: fido2-cred -M -h — PRESS BOOTSEL
    made, self attestation verified, hmac-secret bit signed
>>> ga-salt1 / ga-salt1-again / ga-salt2 / ga-credB-salt1 / ga-plain — PRESS BOOTSEL
>>> wrote roundtrip.json
```

```json
{
  "device": "/dev/hidraw4",
  "rp_id": "example.test",
  "salt_one": "GBhTPDEbbTBOgrXnMPCYW4upi+GgbMAlGuxxihzFFvU=",
  "salt_two": "CNYnxbT/xMNOHhrA72L9RWnc/ZJ6+HbkSfaXPmPB9qA=",
  "key_source": "key source: constant",
  "cred_a_made": true,
  "cred_b_made": true,
  "ga_salt1": "z42AQ3fmIGLzJHg2uC3lEiGEsH7g3uTc/MK5foNJsGM=",
  "ga_salt1_again": "z42AQ3fmIGLzJHg2uC3lEiGEsH7g3uTc/MK5foNJsGM=",
  "ga_salt2": "abZqaVbZnVOBNhXFzF6s3kw+N1qWx69TkOvO9t2l0xw=",
  "ga_credB_salt1": "UBOv5BrmkcaavSIkBQL7VnRMXVJzB1nVbeSYtmT0ewc=",
  "ga_plain_ok": true
}
```

`./nopress.sh 4`, with the board left alone:

```json
{
  "attempts": 4,
  "answered": 0,
  "refusal_code": "FIDO_ERR_OPERATION_DENIED",
  "bootsel_line": ""
}
```

And `verify.py` ruling on the pair:

```text
      arm: key source: constant
PASS  the transcript says which arm produced it
PASS  two credentials made, self attestation verified, hmac-secret bit signed
PASS  salt one produced thirty-two bytes, twice
PASS  the same salt twice gave the same thirty-two bytes, bit for bit
      salt one vs salt two: 125 of 256 bits differ
PASS  a different salt gave a different key
PASS  the two are unrelated, as far as one sample can say
      credential A vs credential B, same salt: 110 of 256 bits differ
PASS  a different credential gave a different key
PASS  the two credentials are unrelated, as far as one sample can say
PASS  an assertion with no extension still works, unchanged from exp173
PASS  4 attempts, which is enough to call a refusal a habit
PASS  nobody pressed, 4 times, and no key came out
      the word for the refusal: FIDO_ERR_OPERATION_DENIED
PASS  the refusal has a code of its own, and it is not one the PIN family uses
PASS  and it is a code that means a person, rather than a generic denial
```

### The second arm, and the one line it is still missing

The `constant` arm is what the transcripts above were taken on. The `bank8` arm
has been on a board and **half of its run is captured**:

```text
>>> boot 1 — straight from a flash, so the window is zeros and there is no key
    key source: bank8 (secret is in the image: false)
    device secret: UNPROVISIONED — the key did NOT come back
      bank 8 came up 0.0% one-bits
      enrolled at 51.1%, 3419 of 7936 cells changed since
```

That is the guard working, not a failure: `yi26 flash` zeroes the window the key
comes from, so 3,419 of 7,936 cells "changed" and the reconstruction is
nonsense — which the key hash catches. The board then blinks
two-flashes-then-a-pause, and refuses every keyed operation in 0.095 s with a
code of its own:

```text
$ fido2-cred -M -h /dev/hidraw4 < cred.in
fido2-cred: fido_dev_make_cred: FIDO_ERR_UNKNOWN     # CTAP2_ERR_NO_SECRET, 0xE2
    refused: this board has no secret to key anything with
```

And boot 2, after the cable has been out:

```text
    key source: bank8 (secret is in the image: false)
    device secret: reconstructed from SRAM — the key came back
      bank 8 came up 50.7% one-bits
      enrolled at 51.1%, 534 of 7936 cells changed since
```

**534 of 7,936 is 6.73%**, against exp181's 494 and exp182's 486 on the same
board — and against 3,419 on the boot straight after a flash, which is what a
window of zeros scores. The code corrects sixteen of thirty-one per key bit and
was never near it.

The cheapest proof that the arm is actually keyed needs no press at all, because
the two refusals take different lengths of time:

```text
unprovisioned   0.095 s   FIDO_ERR_UNKNOWN            # CTAP2_ERR_NO_SECRET, 0xE2
provisioned    20.109 s   FIDO_ERR_OPERATION_DENIED   # it waited for a finger
```

**What is still not captured is the seven-press round trip on this arm** — the
same salt twice, against a secret that is in no file. [`./bank8.sh`](./bank8.sh)
puts the board in the state for it, and `./roundtrip.sh bank8` would run it.

### Two ways this experiment wasted somebody's fingers

Both were the instrument, both are fixed, and both are the same mistake as the
LED one — a step that spends a person without checking it is spending them on
the right thing.

- **`roundtrip.sh` flashed `target/exp189.uf2` unconditionally.** Run against a
  board provisioned on the `bank8` arm, it reflashed the `constant` one over it,
  zeroed the SRAM the key came from, and spent seven presses re-measuring an arm
  that was already captured — the transcript said `arm: key source: constant`
  and nobody read it until afterwards. The arm is an argument now
  (`constant` | `bank8` | `keep`), and the script refuses to ask for the first
  press at all if the board's log says `UNPROVISIONED`.
- **`check.sh` ruled on four fabricated records and never on the real two.** A
  `nopress.json` its own verifier refused — a key that came out while somebody
  was still pressing out of habit — left `check.sh` green. The instrument was
  being tested and the measurement was not. It now rules on the checked-in
  transcripts too, and fails if only one of the pair is present.

**The two Hamming distances are reported and not asserted to be 128.** One
sample of one HMAC lands where "unrelated" lands; what `verify.py` requires is
that they are not identical and that at least 64 of 256 bits moved, because a
salt that barely changes the answer is a bug rather than a coincidence.

## Next

**exp190 — the vault that needs a finger.** The 32 bytes become an AES-256-GCM
key over a CLI's configuration directory, an environment variable points the CLI
at a decrypted copy on a tmpfs, and the copy is wiped when it exits. Its subject
is a mock CLI written here, not a real one: a CLI that authenticates against a
network service is somebody else's product with somebody else's release
schedule, and an experiment that cannot be re-run in five years is not an
experiment. What it owes the reader instead is the list of properties a real CLI
must have for any of this to apply to it — and a second mock that quietly
violates one of them, so that "the redirection worked" and "nothing was left
behind" are two assertions rather than one.
