# exp192 — the salt the browser sends

[exp189](../exp189-the-same-salt-twice/) got the same thirty-two bytes back from
the same salt, twice, through `libfido2`. [exp191](../exp191-the-vault-that-needs-a-finger/)
turned those bytes into a vault that is ciphertext without a finger. The obvious
next client is a browser, because WebAuthn's `prf` extension **is** `hmac-secret`
wearing a different name — and that is exactly where this stops being obvious.

**A page hands `prf.eval.first` some bytes. Something else arrives at the
authenticator.** If that is true, a vault sealed by the CLI cannot be opened by
the browser, the same board and the same credential will produce two different
keys, and every symptom of it looks like the board being broken.

On the [authenticator road](../README.md#the-authenticator-road).

> **Verified on hardware, 2026-08-29.** A browser sends
> `SHA-256("WebAuthn PRF" ‖ 0x00 ‖ input)`, not the input — measured by having
> the board say what it received, and matching the candidate on every byte the
> log carried. Getting there cost **four corrections to exp189's contract**,
> every one of which had ended the conversation before the board's LED could
> light, and **none of which `libfido2` can see**. Told that derived salt, a
> second stack that could not have computed it returns **the same thirty-two
> bytes**. See [Expected output](#expected-output).

## The question, and why reading the spec is not an answer

The WebAuthn specification derives a salt rather than passing one through:
`SHA-256("WebAuthn PRF" ‖ 0x00 ‖ input)`. [`salt.py`](./salt.py) writes that
down as **one candidate of three** — beside the input sent unchanged, which is
what a reader of the CTAP2 spec alone would expect and what `fido2-assert` does
with its salt line, and beside a plain `SHA-256` of the input, which is what a
client needing merely *some* thirty-two bytes might do.

Naming them is not deciding between them. This repository's method is that a
claim about somebody else's software is settled by measurement, and there is
exactly one party in the exchange reporting what it *received* rather than what
it sent: the board. So [exp189](../exp189-the-same-salt-twice/) grew a build
flag —

```console
EXP189_LOG_SALT=1 cargo build --release      # off by default
```

— under which it prints the decrypted salt beside the length it already prints.
**A salt is not a secret**: the client chooses it, sends it, and exp190 stores
one in the clear next to the file it opens. The *output* is the key, and nothing
prints that; `check.sh` asserts both halves of that sentence.

The flag is off by default so exp189's own transcripts still describe the
firmware they were taken on.

## The second way to get a different key, and it is ours

exp189 derives `CredRandom` from one of two domain strings:

```rust
let domain = if with_uv { b"credrandom-uv" } else { b"credrandom-noUV" };
```

So **the same salt and the same credential give a different key depending on
whether user verification happened** — which is correct, and is also a trap the
moment a second client is involved. This board's `getInfo` advertises `uv` while
having no PIN set. A browser that decides to ask for user verification therefore
gets a key the CLI will never reproduce, and nothing in either tool's output
says why.

The page evaluates `prf` twice, once with `userVerification: "discouraged"` and
once with `"required"`, for that reason alone. Two calls are the minimum that
can show a divergence; one call can only be a number.

## Three smaller things a browser changes

**The origin.** WebAuthn refuses `file://` — an opaque origin has no relying
party id to derive — and refuses plain http off `localhost`. So this experiment
needs a server where the WebUSB track needed none, and
[`serve.py`](./serve.py) is exp174's, unchanged but for the port. This is the
opposite of the constraint the browser track carries elsewhere in this
repository, where a `file://` grant is the thing worth having.

**The relying party id binds the credential to the origin.** exp189's
credentials are made against `example.test`; a page on `http://localhost:8192`
can only use `localhost`. A credential must therefore be registered *by the
page*, and any CLI cross-check has to be told the same rp id — which
`fido2-assert` will accept, so the direction that matters still works.

**The browser is a third unrelated client, and that is the point.**
[exp173](../exp173-a-client-that-is-not-ours/) made the case that a key this
repository's own client can read proves less than one somebody else's tool can:
exp189 answered it with `libfido2`, exp191 with this repository's own CTAP
client, and a browser is the third stack — one that reaches the board through a
CTAP implementation nobody here wrote, from a page that cannot see a device at
all.

**Registration hands over nothing.** `hmac-secret` is not evaluated during
`makeCredential`, so `create()` can report `prf: {enabled: true}` and no bytes.
Getting a key needs a second call and therefore a second press. `verify.py`
treats bytes at registration as a **failure**, because on this device model they
could not have come from the board.

## What the browser actually sent

```text
board:                0b6137d0e36e072d3f54fbfc3c4bea2117e86dd3f2517f54dfd5179ea
prf-prefixed-sha256   0b6137d0e36e072d3f54fbfc3c4bea2117e86dd3f2517f54dfd5179ea49d3b67
raw                   6578703139322070726620696e707574
plain-sha256          24e9da58d166e024f1f1b71eaaf681a53309b90cce01ac937e68b8567e3c3d38
```

**The spec's derivation, and not the input.** So a vault sealed by exp191's CLI
cannot be opened from a page that hands the same string to `prf.eval.first`, and
nothing in either tool says why: the board is working, the browser is working,
and the keys differ.

The board's log carried **28 of the 32 bytes** — its ring has a fixed line width
and cut the line in the middle of a byte. Twenty-eight bytes name the candidate
past any argument (a coincidence is 2⁻²²⁴) and are still not the salt, so
`verify.py` passes the *identification* and fails the *reading*, in two separate
lines. The firmware now prints the salt sixteen bytes at a time; the whole
reading is owed to the next run.

## Four things exp189 claimed or omitted, and what each one cost

None of these is about `prf`. Each is a place where exp189's contract said
something a browser reads and `libfido2` does not, and each one ended the
conversation **before the board's LED ever lit** — which from the bench looks
exactly like a board that is broken.

| what the contract said | what Chrome did | what it cost |
| --- | --- | --- |
| `uv: true` in `getInfo`, while `getUVRetries` returns `CTAP2_ERR_UNSUPPORTED_OPTION` | asked `clientPIN sub=7`, got the contradiction | stopped; no `makeCredential` sent |
| no `authenticatorSelection` (0x0B) | asked "which key do you mean", got `CTAP1_ERR_INVALID_COMMAND` | stopped; that command **is** the one that lights the LED |
| `clientPin: false` **with** `pinUvAuthToken: true` | read it as "supports a PIN, hasn't got one" and offered to set one | a PIN dialog on a board whose whole verification story is one button |
| key-agreement `COSE_Key` with kty, crv, x, y and **no `alg`** | parsed it strictly, and stopped | the tunnel `hmac-secret` rides on; the board's log ends at `clientPIN sub=2` |

The first three are switched by build flags, so one board can be asked the same
question under both contracts —
`EXP189_ADVERTISE_UV=0`, `EXP189_SELECTION=1`, `EXP189_ADVERTISE_PIN=0`. The
fourth is a plain omission and is fixed outright: CTAP 2.1 requires `alg` on a
key-agreement key, and `-25` was simply missing.

**`uv: true` was not a lie.** exp189 really does have on-device verification —
[exp187](../exp187-the-three-taps-and-the-reset/)'s three-tap gesture, which
`makeCredential` honours. What it does not have is the rest of the contract that
comes with saying so, and a browser reads the whole contract.
[exp169](../exp169-what-it-says-it-can-do/) asked what a device says it can do;
this is what happens when a client believes the answer.

With all four corrected, the chain runs end to end:

```text
makeCredential: rp="localhost", user=16B (rk=false, uv=false)
presence: BOOTSEL read low at 2724 ms
credential created: authData 194B, total 290B (rk=false)
prf at create: {"enabled": true}                 <- no bytes, as a security key must
clientPIN: pinProtocol=1 sub=2                   <- the hmac-secret tunnel
getAssertion: rp="localhost", allow=1 (uv_req=false)
presence: BOOTSEL read low at 2343 ms
hmac-secret: 32B salt in, 32B out, UV=false
assertion signed: 233B
```

and the page receives thirty-two bytes:

```text
prf.results.first  29805b806accd1043997408fece041d46ce204e4d83bafcf2022d0c1ebc2da3e
authData flags     0x81   (UP=true, UV=false, ED=true)
```

## What the third button found

`userVerification: "required"` is now refused by Chrome **before any press**,
with "this device cannot be used" — because the corrected contract honestly does
not claim a configured verification method. That is the trade the third flag
makes, stated rather than hidden: a board that stops over-claiming also stops
being offered for requests it cannot satisfy, which is the correct outcome and
also means the `credrandom-uv` / `credrandom-noUV` divergence **is not measured
here**. Measuring it needs a build that advertises `uv` *and* answers
`getUVRetries`, which is a fifth correction and a round of its own.

## What cannot be automated, and why that is stated first

Chrome reaches the board through its own CTAP stack on `/dev/hidraw` — not
through WebUSB — so there is no permission to pre-grant and nothing a script can
claim on the browser's behalf. A headless browser has neither a user gesture nor
a finger. [exp174](../exp174-a-deadline-nobody-mentioned/) established that
shape; this experiment inherits it whole: **a person, a visible window, and
three presses.**

The browser also will not say when the board wants a finger. It shows its own
dialog and waits. The LED is the only signal, exactly as everywhere else here,
and all three windows in this run are windows to press — including the third,
because a refusal that comes from the browser and a refusal that comes from
nobody pressing are different findings.

## Running it

```console
./check.sh                       # needs nothing
./run.sh                         # a browser, a person, three presses
EXP192_SKIP_FLASH=1 ./run.sh     # again, keeping this board and this credential
```

`run.sh` flashes exp189's **`constant`** arm with the salt flag. That choice is
deliberate: the `bank8` arm's key would be zeroed by the flash and cost a cable
pull to bring back, and nothing measured here depends on where the device secret
lives. What is under test is what the *client* sends.

Then it serves `page/`, captures the board's log for the whole session, opens a
window, and waits for the page to post three entries back rather than for a
clock. [`analyse.py`](./analyse.py) puts the three accounts of the session
beside each other and [`verify.py`](./verify.py) rules on them.

The pairing of a browser call to a logged salt is **positional**, and that is
said out loud rather than hidden: the board's log cannot name which call a salt
belonged to, so a run whose counts differ is a run that cannot be paired, and
`verify.py` refuses it instead of guessing.

## What this will not establish

**That a browser and a CLI interoperate without being told.** The cross-check
shows one authenticator giving one answer to one salt, which is what makes
exp191's vault openable from either side — but only once the CLI is told the
salt a browser derives. Left to themselves the two disagree, and that is the
finding rather than a footnote to it.

**That `prf` works on any other board.** One authenticator, one browser, one
version each; [exp176](../exp176-the-same-question-of-two-devices/)'s caveat
applies unchanged.

**That the derivation is stable.** A browser is somebody else's software on
somebody else's release cycle, which is the objection
[exp177](../exp177-the-same-chip-somebody-elses-decisions/) answers for binaries
by pinning them and cannot answer for a browser at all. What is recorded here is
a dated observation of one build, and
[exp175](../exp175-the-secret-is-the-file/)'s reading applies: a capture ages.

## Expected output

```text
      browser: Mozilla/5.0 (X11; Linux x86_64) ... Chrome/151.0.0.0 Safari/537.36
      rp id:   localhost    prf input: 'exp192 prf input'
PASS  the browser registered a credential on this board
      prf at create: {"enabled": true}
PASS  create() reported prf without handing over a key, as a security key must
PASS  every get() has a salt the board logged for it (1 calls, 1 salts)
      uv=discouraged: salt 0b6137d0...dfd5179ea
                    = prf-prefixed-sha256 (first 28 of 32 bytes, the log cut mid-byte)
PASS  uv=discouraged: the salt the board received is a candidate this repository named
      NOTE  uv=discouraged: the reading is a prefix. The identification stands;
            the reading is owed to the next run.
PASS  uv=discouraged: thirty-two bytes came back to the page
      only 1 of 2 evaluations produced a key; UV is not compared
```

**Completeness is a note and not a rule, and the distinction is the point.**
What this experiment claims is *which* salt a browser sends, and 28 bytes settle
that past any argument. How much of it the log carried is a fact about the
instrument on the day — and that instrument is already fixed, so failing an aged
capture for a defect that no longer exists would make the verifier refuse the
very transcript it was written to rule on. `check.sh` asserts the fix in the
firmware's source instead, where a regression would actually live. A capture
ages, and is recorded rather than repaired.

## The cross-check, which is one press and the sentence worth having

[`./crosscheck.sh`](./crosscheck.sh) takes the browser's credential id and the
salt the board received, hands both to `libfido2` — which has never heard of
WebAuthn's `prf` extension and cannot derive that salt on its own — and compares
its thirty-two bytes with the page's.

It leans on exactly one inference and says so where it makes it: the salt is
reconstructed from the *named candidate* rather than from the truncated log
line, because feeding libfido2 twenty-eight bytes would ask a question nobody
asked. `crosscheck.json` records which candidate, so the inference is visible.

**Run, 2026-08-29:**

```text
salt         0b6137d0e36e072d3f54fbfc3c4bea2117e86dd3f2517f54dfd5179ea49d3b67
browser key  29805b806accd1043997408fece041d46ce204e4d83bafcf2022d0c1ebc2da3e
cli key      29805b806accd1043997408fece041d46ce204e4d83bafcf2022d0c1ebc2da3e
```

**The same thirty-two bytes.** And the agreement is a statement about the
*board*, not about two clients agreeing with each other: `libfido2` could not
have produced that salt on its own, so what is shown is that one authenticator
gives one answer to one salt regardless of which stack asks. Told the browser's
derivation, exp191's vault opens from either side.

What it is not is a statement about *the browser and the CLI interoperating by
default*. They do not: the CLI has to be told the salt a browser would derive,
which is the whole finding at the top of this file.
