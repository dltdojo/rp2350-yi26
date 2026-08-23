# exp177 — the same chip, somebody else's decisions

[exp176](../exp176-the-same-question-of-two-devices/) asked this board and a
commercial key the same question and sorted the fourteen differences by kind:
ten were **code the board could write**, three were policy numbers, one was
certification. [exp178](../exp178-the-shape-of-the-contract/) then showed that a
library closes all ten of the code ones and none of the certification one.

This is the third answer, and the first that is neither a library nor a
product: **pico-fido, flashed to the same Pico 2 that ran exp174.** Same
silicon, same `fido2-token`, a different team's decisions. The question exp176
could not ask is the one this answers — of the ten differences called code the
board could write, how many has somebody else actually written, here?

The eleventh on the [authenticator road](../README.md#the-authenticator-road).

> **Verified on hardware, 2026-08-23.** pico-fido **8.0** for `pico2`, the
> upstream release, pinned by SHA-256. **Nine of exp176's ten**, and the tenth
> is not what `fido2-token` said it was. It claims a **real AAGUID** and carries
> **no certificate**, which splits exp176's one uncloseable difference into a
> half that is code and a half that is not. And it **does not wait for a
> person**: three credentials in 437–501 ms with nobody pressing anything, the
> user-presence bit set on every one, and `fido2-cred -V` verifying the last.

> **Read, never linked.** pico-fido is **GPL-3.0** over an **AGPL-3.0** SDK;
> this repository is Apache-2.0. Those do not mix and this experiment never
> asks them to: not one line of their code is compiled into anything here.
> `setup.sh` fetches one released binary and checks its SHA-256 into a
> git-ignored directory. Running somebody's program is not a licensing event.
> This is the opposite of exp178, where Apache-2.0 on both sides was what made
> reuse legal — the two rungs measure the same distance from different sides of
> a licence boundary.

## Before the board: reading the image

A UF2 says which family each block belongs to and which address it wants, and
both are readable with no board attached. Every UF2 this repository has ever
dropped on a Pico 2 it also built. This is the first that somebody else built,
and `preflight.py` is the habit that difference deserves:

```text
pico_fido_pico2-8.0.uf2: 1745 blocks
  family 0xe48bff57  absolute                   1 blocks  0x10ffff00..0x11000000  256 bytes
  family 0xe48bff59  RP2350 Arm Secure       1744 blocks  0x10000000..0x1006d000  446464 bytes

  the image proper: 0x10000000..0x1006d000, 446464 bytes (436.0 KiB)
  that is 6.8× exp142's 64 KiB A/B slot
```

Two things came out of it before anything was flashed.

**One block asks for an address this part does not have.** `0x10ffff00` is the
last 256 bytes of a *16 MiB* window; a Pico 2 has 4 MiB. It is 256 bytes of
`0xef` filler in the `absolute` family, which means the address is taken
literally rather than as an offset. What the bootrom does with it is the
bootrom's decision, and this experiment reports that it is there rather than
predicting the outcome. The board came up.

**436 KiB does not fit the update road's geometry.** exp142's A/B slots are
sixteen sectors — 64 KiB — each. For scale, on the same road: exp174's entire
firmware is 74,680 bytes, exp178 measured OpenSK's engine at 121,184, and this
is 446,464. Three answers to one question, spanning 6×.

Which made the pre-flight question worth asking: **does this board carry a
partition table?** If it did, dropping a 436 KiB image would be
[exp144](../exp144-one-file-either-half/)'s subject at six times the slot size.
[exp138](../exp138-what-the-rom-already-knows/) answers it without writing
anything — flash it, read the log, and the ROM says `partition count: 0`. It
does not. The image lands plainly at `0x10000000`.

### And our own tool refused it

```text
yi26: UF2 family ID is e48bff57, expected e48bff59 (rp2350-arm-s) —
      this file is for a different chip
```

`yi26 flash` reads the **first** block's family and stops. The first block of
this image is the `absolute` padding one; the other 1,744 say `e48bff59`. The
file is for exactly this chip, and the message names the wrong cause — the
failure mode [debugging on a phone](../../docs/debugging-on-a-phone.md) is
about, arriving on a desktop. It is written down here rather than fixed here,
because `yi26` is shared by every experiment and a tool change belongs in its
own change, not smuggled into an experiment's.

The way round is the way a person would do it anyway: `yi26 bootsel`, then copy
the file to the boot drive and let the ROM decide.

## What the three devices say about themselves

| | board (exp174) | **pico-fido 8.0** | Yubico Security Key |
|---|---|---|---|
| versions | `FIDO_2_0` | `U2F_V2, FIDO_2_0, FIDO_2_1, FIDO_2_2, FIDO_2_3` | `U2F_V2, FIDO_2_0, FIDO_2_1_PRE` |
| extensions | — | `uvm, credBlob, credProtect, hmac-secret, largeBlobKey, minPinLength, hmac-secret-mc, thirdPartyPayment` | `credProtect, hmac-secret` |
| algorithms | — | `ES256, ES384, ES512` | `es256, eddsa` |
| options | `nork, noup` | `rk, credMgmt, authnrCfg, largeBlobs, perCredMgmtRO, pinUvAuthToken, setMinPINLength` (+ `noalwaysUv, noclientPin, nomakeCredUvNotRqd`) | `rk, up, noplat, clientPin, credentialMgmtPreview` |
| max credentials in list | 0 | 16 | 8 |
| max credential length | 0 | 1024 | 128 |
| pin protocols | — | `1, 2` | `1` |
| **aaguid** | **all zero** | **`89fb94b7…8145`** | **`b92c3f9a…163b`** |

It is not a lesser device than the commercial key on this evidence. It claims
three version strings the key does not, six extensions the key does not, and
seven options the key does not. What the key has and it does not: `up`, `plat`,
and `eddsa`.

## The ten, ruled on by a third team

`compare.py` reads the list out of exp176's own `comparison.json`, so if that
categorisation changes this changes with it.

| exp176 said the board lacked | written here? |
|---|---|
| `U2F_V2` | yes |
| `FIDO_2_1_PRE` | yes — and past it, to `FIDO_2_3` |
| `credProtect` | yes |
| `hmac-secret` | yes |
| `rk` | yes, on the same 4 MiB of flash |
| `clientPin` | yes (supported; none set here) |
| `credentialMgmtPreview` | yes, as full `credMgmt` |
| no algorithms advertised | yes |
| `eddsa` | **no** |
| `pin_protocols=1` | yes |

**Nine of ten.** Which is the answer the road wanted: exp176 said those ten
were code somebody could write, and somebody wrote nine of them on this chip.

### The tenth was nearly ruled the wrong way

`fido2-token -I` prints this device's third algorithm as `unknown`, and a first
pass read that as "a third algorithm, so `eddsa` is probably covered". It is
not. `algorithms.py` asks the device for `getInfo` field `0x0a` and reads the
COSE identifiers as numbers:

```text
-7 ES256, -35 ES384, -36 ES512
```

Three ECDSA curves and no Ed25519. `unknown` was libfido2 not naming COSE −36,
not the device being vague. **The ruling that survived is the one that asked
the device instead of the host's pretty-printer.**

Two smaller things came out of asking directly:

- **Both of this repository's host-side CBOR readers refuse its `getInfo`.**
  exp169's — copied forward into exp170, exp171 and exp172 — rejects text map
  keys. exp173's has no major type 7, so the first `true` in an options map
  stops it. Neither device they were written against ever sent either. The
  reader that works is [exp178](../exp178-the-shape-of-the-contract/)'s, written
  the same day, and it is canonical-only: **pico-fido's `getInfo` is canonical.**
- **It sends `CTAPHID_KEEPALIVE` while it thinks** — one packet, `0x3b`, payload
  `0x01` (PROCESSING). [exp174](../exp174-a-deadline-nobody-mentioned/) measured
  what that packet is for on this repository's own board; here it arrives from
  firmware nobody here wrote, and a client that treats the first reply as the
  answer reads `0x01` as a CTAP status byte and reports an error the device
  never sent. This experiment did, once, before it read its own exp174.

## The identity axis, which is what the road sent this experiment to look at

One registration, and the attestation says:

```text
format              : packed
AAGUID in authData  : 89fb94b706c936739b7e30526d968145
certificate chain   : False
```

**A real AAGUID and no certificate behind it.** exp176 classified the AAGUID
difference as *certification the chip cannot anchor*, and this is not a
counterexample — it is the sentence getting more precise. Sixteen bytes that a
firmware asserts about itself are **code**: identical on every board that
flashes the same image, and anyone can put anything there. What exp176 named is
the other half — an authority that vouches for the claim, and a secret the
device can keep so the vouching means something. Neither is a thing a firmware
can assert about itself, and neither arrives with better code.

pico-fido's headline answer to the second half is **Secure Boot with Secure
Lock**: a master key in OTP, unreadable outside secure code, used to encrypt
what is in flash — which would close
[exp175](../exp175-the-secret-is-the-file/)'s demonstration B exactly. **This
experiment does not turn it on**, because burning a fuse is a boundary this
repository's roads deliberately never cross. So what was measured is pico-fido
*without* its main defence, and exp175 applies to this image as it applied to
ours. That is a limit of the measurement and not a criticism of the firmware,
and it is stated here rather than in a footnote.

## It does not wait for a person

exp171 wrote the rule down: **the bit that says a person was present is the
device's own word, and nothing in the protocol checks it.** Every build in this
repository since then earns it, and exp171's `check.sh` fails if an unattended
build ever sets it.

Asked of firmware nobody here wrote, with no PIN set on the device:

```text
device: /dev/hidraw4 — 3 credentials, and nobody is asked to press anything
  round 1: made a credential in 501 ms, UP claimed: True
  round 2: made a credential in 447 ms, UP claimed: True
  round 3: made a credential in 445 ms, UP claimed: True
  fido2-cred -V accepted the last one
```

Half a second, three times, with the user-presence bit set — and a client
verifying it. A script cannot prove that nobody pressed a button; what it can
show is that **the device did not wait**, which half a second answers on its
own. The measurement was also repeated after 150 seconds of no contact with the
board, to rule out a recent press being cached: still one second, still `UP`.

`fido2-cred -V` is the tool [exp173](../exp173-a-client-that-is-not-ours/) found
refuses a credential whose UP bit is clear — the refusal this repository misread
as "malformed attestation" for five experiments. Here it accepts one: **the bit
did its whole job without being earned**, all the way through a client that
checks for it.

**Why is not established here.** A plausible mechanism is visible in the
project's 7.x sources: the button is consulted only when a request carries a
`pinUvAuthParam`, and the presence flag is set unconditionally otherwise — with
no PIN set, nothing carries one. That is an explanation offered for a **7.x**
source against a **8.0** binary, and this experiment does not claim it is what
8.0 does. What it claims is the measurement. Nor was the device tested with a
PIN set, which is the configuration where that path would be exercised.

## Where this does not go

- **No fuse was burned**, so Secure Boot and Secure Lock — the reason this rung
  exists — are described from upstream's documentation and not measured. What is
  measured is the firmware without them.
- **One board, one release, one host.** pico-fido 8.0 for `pico2`, on Ubuntu.
- **`getAssertion` was not exercised**, only `makeCredential`. The presence
  finding is about the command that was run.
- **No PIN was set**, and setting one changes the device's state in a way this
  experiment would then have to undo.
- **This is not a security advisory** and is not written as one. It is a
  measurement of a device this repository flashed onto its own board, published
  with the method beside it, in a repository whose own exp171 made the same
  point about its own firmware first.
- **Nothing about the 0x10ffff00 block was resolved** — only that it is there
  and that the board came up anyway.

## Running it

```console
./setup.sh          # download the pinned release and check its SHA-256
./preflight.py firmware/pico_fido_pico2-8.0.uf2    # read it before flashing it
# then: yi26 bootsel, and copy that file to the boot drive by hand
python3 ../exp176-the-same-question-of-two-devices/probe.py /dev/hidrawN > picofido.json
./algorithms.py > algorithms.json
./presence.sh 3     # needs nobody, which is the finding
./register.sh       # asks for a press; it turns out not to need one
./compare.py
./check.sh
```

`yi26 flash` will refuse the file — see above.

## Putting the board back

pico-fido answers no 1200-baud touch of this repository's, so the way back is
**a hand on BOOTSEL**, then `yi26 flash` with any experiment's UF2. That one
action is why this experiment is Needs 2 and not Needs 1. The board should end
up back on exp174, and `check.sh` reports the absence of a pico-fido device as
`SKIP` rather than as a failure for exactly that reason.

### And most of it is still on the board

Putting exp174 back printed its own arithmetic:

```text
flashed 74752 bytes to 0x10000000 over PICOBOOT (19 sectors erased), and rebooted into it.
```

Nineteen sectors is 77,824 bytes. The image that was there was **446,464**. So
roughly 360 KiB of somebody else's firmware is still sitting in this board's
flash, past the end of what the new image needed erased — inert, because
nothing points at it, and present, because nothing removed it.

That is [exp175](../exp175-the-secret-is-the-file/)'s second false comfort,
arriving from the outside: *a reflash does not make old bytes gone.* exp175
demonstrated it against this repository's own images and its own key. Here it
happens to a third party's, on the way out of the experiment, without anybody
intending it. **This is a deduction from the flasher's own report and not a
flash dump** — confirming it would cost another BOOTSEL press and a PICOBOOT
read, which exp141 is the experiment for.

## Expected output

```text
PASS  python3 present
PASS  fido2-token present (the host's own tool)
PASS  the README says what licence the measured firmware is under
PASS  no third-party binary is committed to this repository
PASS  the image on disk is the one setup.sh pins, by SHA-256
PASS  preflight.json is checked in
PASS  the image is for this chip: 1744 blocks of the RP2350 Arm Secure family
PASS  and it carries one block asking for 0x10ffff00 — 15 MiB into a 4 MiB part
PASS  there is a boot block at flash offset 0, so it is bootable at all
PASS  it is 6.8× exp142's 64 KiB A/B slot — it would not fit in one
PASS  picofido.json is checked in
PASS  algorithms.json is checked in
PASS  comparison.json is checked in
PASS  picofido-attestation.json is checked in
PASS  presence.json is checked in
PASS  the comparison re-runs from the checked-in record
PASS  9 of exp176's 10 code differences were written by another team on this chip; 1 was not
PASS  the one it did not write is eddsa — it offers three ECDSA curves instead
PASS  and that ruling came from the device's own COSE identifiers, not from libfido2 printing `unknown`
PASS  it claims a real AAGUID (89fb94b706c936739b7e30526d968145), in getInfo and in the attestation alike
PASS  and carries no certificate chain — the claim without the authority, which is exactly the half exp176 called certification
PASS  the attestation format is packed, as the board's is
PASS  every credential it made claimed the user-presence bit
PASS  and the slowest took 493 ms, with nobody asked to press anything
PASS  a live pico-fido re-probes to the same record
PASS  the README rules on exp176's list, not one of its own
PASS  the README ties the identity half to exp175
PASS  the README ties the presence finding to exp171
```

That run was captured with the board still running pico-fido, which is why the
live re-probe passes rather than skipping. Once the board is back on exp174 the
last check reports `SKIP` and the record stands on its own.
