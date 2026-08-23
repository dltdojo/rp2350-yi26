# exp176 — the same question, asked of two devices

[exp175](../exp175-the-secret-is-the-file/) attacked this board's key. This one
holds it up next to a commercial one and asks both the same question —
`fido2-token -I`, then one registration each — and sorts the differences by
kind. The counts are the argument.

The ninth on the [authenticator road](../README.md#the-authenticator-road), and
the first that measures the distance to a real key instead of asserting it.

> **Verified on hardware, 2026-08-23.** Against a Yubico Security Key
> (`0x1050:0x0120`), `getInfo` and the board's own attestation are captured and
> compared. Ten of the fourteen differences are code the board could write; one
> is an attestation identity the chip cannot honestly anchor — a Yubico
> certificate the board has no counterpart to, which is exactly
> [exp175](../exp175-the-secret-is-the-file/)'s finding. The key's attestation
> is captured through a browser — a touch, no PIN, no shell command — with only
> that key plugged in. See [Running it](#running-it).

## What the two devices say about themselves

`getInfo`, side by side (the fields that differ):

| | board (exp174) | Yubico Security Key |
|---|---|---|
| versions | `FIDO_2_0` | `U2F_V2, FIDO_2_0, FIDO_2_1_PRE` |
| extensions | — | `credProtect, hmac-secret` |
| algorithms | not advertised | `es256, eddsa` |
| options | `nork, noup` | `rk, up, noplat, clientPin, credentialMgmtPreview` |
| pin protocols | — | `1` |
| max credentials in list | 0 | 8 |
| max credential length | 0 | 128 |
| **aaguid** | **all zero** | **`b92c3f9a…163b`** |

The board column is its `EXP174_UP=none` build, the one exp176 registers against
unattended — hence `noup`. Its `button` build differs only in that one option.

## The gap, sorted by kind

`compare.py` assigns each difference one of four kinds, and the assignment is a
claim written down field by field in the source so it can be argued with:

- **code** — software exp174 chose not to write;
- **certification** — an authority or a secret the device structurally lacks;
- **silicon** — hardware the chip does not have or cannot defend;
- **policy** — a limit or counter, not a capability.

On this pair:

```text
code           U2F_V2, FIDO_2_1_PRE, credProtect, hmac-secret, rk, clientPin,
               credentialMgmtPreview, eddsa, pin_protocols, (algorithms not advertised)
policy         max_cred_count_list=8, max_cred_len=128, pin_retries=8
certification  aaguid b92c3f9a…163b
```

**Ten of fourteen differences are code.** The distance from this board to a
commercial key's *feature list* is mostly labour — `rk` needs the on-device
storage [exp145](../exp145-a-place-to-put-it/) already built, `hmac-secret` and
`credProtect` are extensions, `eddsa` is a second algorithm, `clientPin` is the
CTAP 2.1 surface the road cut on purpose because it is where Android's strict
parser trips. A student who did exp168–174 can read each of these and see it is
reachable.

**One difference is not code, and it is the one that matters.** A real AAGUID is
not a string you write; it is an identity a manufacturer is issued, backed by an
attestation key that must stay secret inside a certified device. The board's
AAGUID is sixteen zero bytes — which is not a smaller identity but *no* identity,
the value self-attestation is required to use. And exp175 already showed why the
board cannot honestly do better: a secret its firmware carries is a secret
anyone with the firmware has. **The gap that is not code is exactly the gap
exp175 measured.**

## The attestation makes it concrete

`getInfo` shows the AAGUID difference; a registration shows what hangs off it.
Both attestations here were captured **through a browser** — the exp174 probe
page with `attestation: "direct"`, a touch, no PIN — because that is the
touch-first way a website does it, and it needs no shell command. `attest.py`
decodes the browser's `attestationObject` (a CBOR map) and reports the one thing
that separates an identity from a self-assertion: an **x5c certificate chain**.

| | board | commercial key |
|---|---|---|
| format | `packed` | `fido-u2f` |
| authData AAGUID | all zero | **all zero** |
| certificate chain | **none** | **one certificate** |
| what it says | *this credential signed these bytes* | *…and Yubico's CA vouches for the device* |

Two corrections this experiment forced on its own first draft, both worth
keeping because a student would make the same mistakes:

- **The AAGUID field is not the discriminator.** The board self-attests
  `packed` with a zero AAGUID; the key attests `fido-u2f`, which the spec
  requires to zero the AAGUID field too. So *both* show zero there, and a naive
  "compare the AAGUID bytes" would call them the same. The real difference is
  the certificate. (getInfo *does* advertise the key's non-zero AAGUID,
  `b92c3f9a…163b` — the identity is claimed there and proved by the cert, and
  is absent from the board in both places.)

- **The browser does not strip a direct attestation on localhost.** An earlier
  run seemed to show the key returning an anonymised, certificate-less
  attestation — but that run had registered against the *board*, which was still
  plugged in as a second cross-platform authenticator. With the board removed,
  the key returns its certificate in full. The lesson is about the instrument,
  not the browser: when two authenticators are present, confirm which one
  answered.

The certificate names its chain of authority:

```text
subject  Yubico AB, Authenticator Attestation, Yubico U2F EE Serial 1073904040
issuer   Yubico U2F Root CA Serial 457200631
```

That is the sentence exp175 showed this chip cannot back: an attestation key
that stays secret inside a certified device, rooted in a CA the FIDO Metadata
Service lists. The board's attestation is a genuine self-attestation — correct,
verifiable, anchored in nothing but itself. **The missing certificate is not a
missing feature; it is a missing authority, and the reason is a secret this chip
cannot keep.**

## Where this does not go

Side-channel resistance, fault-injection hardening, the certification process
itself — this experiment has neither the equipment nor the standing to measure
them. It points at the fact that the commercial key is FIDO-certified and the
board is not, and stops there. The [RP2350 Hacking Challenge](https://www.raspberrypi.com/news/security-through-transparency-rp2350-hacking-challenge-results-are-in/)
is where that ceiling was measured by people who could; this file does not
pretend to redo it.

## Running it

```console
./check.sh          # the comparison and the board's attestation — no PIN, no touch
python3 serve.py &  # then open http://localhost:8176, register each device (a touch)
./drive.sh          # or the command-line path: both getInfos and the board's attestation
```

`check.sh` works from the checked-in record with nothing attached, and re-probes
live if a board and a key are present. The browser path is the one that captured
the record here: with **only the key plugged in** (so no other authenticator can
answer), open the page, register with `label` = `commercial key`, and touch it —
this key needed no PIN for a non-resident, `userVerification: discouraged`
registration. `drive.sh` is the command-line alternative; on a key that enforces
a PIN it will prompt for one, typed at your terminal and never seen by the
script. Either way the credential is **non-resident**: it consumes no slot and
stores nothing on the key, the ordinary thing a website does.

## The board's key is still a test key

The board half runs on the `EXP174_UP=none` build so it needs no finger; its
credential is derived from the same compiled-in test key every experiment on
this road uses, and exp175 is the experiment about what that costs. The
commercial key's secret is the thing this comparison is *for*: it is where a
real one lives, and where the board's does not.

## Expected output

See [capture.txt](./capture.txt), and `comparison.json` / `board-attestation.json`
for the machine-readable record `check.sh` re-checks. `yubikey-cred.out` and
`yubikey-attestation.json` appear once `drive.sh` has been run with a key.
