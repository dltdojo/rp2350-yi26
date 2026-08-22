# exp174 — a deadline nobody mentioned

Every experiment from [exp168](../exp168-a-security-key-that-knows-nothing/) to
[exp173](../exp173-a-client-that-is-not-ours/) was driven by a command-line
tool. A command-line tool waits as long as it is told. **This one is driven by
a browser**, which does not.

The seventh on the [authenticator road](../README.md#the-authenticator-road).

> **Verified on hardware, 2026-08-22 and 2026-08-23.** Chrome 151 registers a
> credential and logs in with it, on a page served from `http://localhost` and
> on `webauthn.io`. What the chase produced is two findings, and only the second
> is about the protocol. See [Expected output](#expected-output).

## What it set out to measure, and what it found instead

The plan was to find what a browser demands that `libfido2` does not. The
answer is **nothing**. exp173's firmware, unchanged, registered and logged in
against Chrome on the first attempt.

What the browser did do is **give up**, sometimes, on a device that was working
perfectly — and say so with the same three words it uses for everything else.

## One: this firmware was slow, and every check said it was fine

Between the button press and the finished credential there were **eleven to
twenty-one seconds**, in every run since
[exp171](../exp171-a-credential-nobody-asked-for/). Deriving the key takes
44 ms. Signing takes 54 ms. The rest was one statement nobody had ever timed:

```rust
let mut nonce = [0u8; 32];
trng.blocking_fill_bytes(&mut nonce);
```

Measured on this board, three consecutive fills:

```text
32 bytes of TRNG took 15367250 us
32 bytes of TRNG took 21396565 us
32 bytes of TRNG took  6859753 us
```

**[exp109](../exp109-hardware-trng/) had already found this and written it
down.** `embassy-rp` defaults `sample_count` to 25, which samples the ring
oscillator faster than it decorrelates: the health tests reject the work and it
is done again. exp109 measured 64 bits at 0.38 s, then 31.4 s, then 14.5 s on
that default against 5–6 ms at 1000, and said in as many words that *something
which always works but sometimes takes half a minute is harder to find than
something that breaks, because there is nothing to catch: no error, no panic,
no log line. Just a gap.*

exp171, exp172, exp173 and this experiment's own first builds all used
`Config::default()`. **Every credential they made was correct and every
signature verified.** `check.sh` was green in all four. At exp109's number:

```text
32 bytes of TRNG took 11124 us
32 bytes of TRNG took 10750 us
32 bytes of TRNG took 11030 us
```

A factor of about 1400, and the variance is gone with it.

**What found it was a browser giving up** — which is worth saying plainly,
because the finding is not "we used the wrong constant". It is that a
repository which measures things wrote the warning, kept the measurement, and
walked into it sixty experiments later, and none of its own instruments
noticed. The one that did was somebody else's, and it was not looking.

## Two: silence has a price

A device waiting for a finger sends nothing. A host cannot tell that apart from
a device that has died, so it stops waiting — and the specification's answer is
`CTAPHID_KEEPALIVE`, one status byte whose only job is to say *still here*.

With the TRNG fixed, the two arms are the same source and the same board,
differing in that packet. The board's own clock decides when the answer leaves,
so both answer at the same moment:

| | floor | keepalives | the board | the browser |
|---|---|---|---|---|
| **`KEEPALIVE=off`** | 25000 ms | **0** | credential made, `UP=1` | **`NotAllowedError`** |
| **`KEEPALIVE=on`** | 25000 ms | **249** | credential made, `UP=1` | **accepted** |

**Both boards did the work.** Both built a correct, signed credential with the
user-presence bit set. Only one of them still had somebody listening.

Below the ceiling it changes nothing: nine seconds of pure silence was accepted
by the same browser in the same session. **The packet is not what makes this
work; it is what makes it keep working when a person is slow.**

Where the ceiling is, from the totals this session measured — device silence
from request to response, whatever caused it:

```text
   9.7 s   accepted        19.5 s   accepted
  14.2 s   accepted        23.6 s   refused
  16.1 s   accepted        25.6 s   refused
                           25.0 s   accepted, with keepalives
```

So a silent device has roughly twenty seconds here. That number belongs to this
browser on this host, and the experiment reports it rather than depending on it.

### What it costs to say it

The keepalives are not free. The same ten-second window took **13.6 s** to
expire when they were being sent, against **10.0 s** in silence, because each
one is a USB write the wait blocks on. The instrument perturbs the subject, and
`drive.sh` prints both numbers rather than one.

## Three: the client says when it leaves, and exp173 was not listening

A browser that has stopped waiting sends `CTAPHID_CANCEL`. exp173 received one:

```text
[ 1885463 ms] in  cid 0000000d ? bcnt 0
[ 1885523 ms]   ? is not implemented here: ERR_INVALID_CMD
```

— and went on deriving a key and signing for a caller who had gone. This build
reads while it waits, so a withdrawn request ends in
`CTAP2_ERR_KEEPALIVE_CANCEL` with **no key derived and no signature made**.

The constant was wrong too, in a way that only broke one direction:
`CTAPHID_KEEPALIVE` was first written as `0xBB`, the byte as it appears on the
wire, where every other command here is stored without the initialisation bit.
It produced exactly the right packets — `0x80 | 0xBB` and `0x80 | 0x3B` are the
same byte — and would have printed `?` for any keepalive *arriving*. A constant
can be wrong in the direction nobody tested.

## Four: one error name for three different things

`NotAllowedError`, with an identical message, came back from:

| after | what had happened |
|---|---|
| 13.0 s | the authenticator refused — nobody pressed in time |
| 116.3 s | the authenticator answered and the browser had left |
| 165.4 s | the person gave up and cancelled the dialog |

The message links to WebAuthn's privacy considerations, so this is deliberate:
**a relying party is not allowed to learn why your key said no.** It also means
the page can never explain to a person what went wrong, which is why this
experiment reads the board's log and not the browser's error.

## Five: the button is alive for ten seconds and nothing says when

Three times in this session's runs a person pressed BOOTSEL and nothing
happened, and every time the board had not been asked yet — the press landed in
the gap before the request arrived, where nothing is watching the pin. The board
has an LED and it was idle throughout.

**This is a defect of the appliance, not of the protocol**, and it is the first
thing on this road that a person rather than a specification would ask for.

## And things the browser does that `libfido2` does not

- **A fresh channel for every operation.** `INIT` → new CID → `getInfo` → the
  command. The device was asked what it can do five times in one session.
- **It re-sends.** After a refusal, the identical `makeCredential` — the same
  `clientDataHash` — arrives again on a new channel 23.6 s later.
- **The relying party's `timeout` bounds nothing.** The page asked for 60 s;
  the dialog was still open at 165 s.
- **`webauthn.io` offers three algorithms** — `-8` EdDSA, `-7` ES256, `-257`
  RS256 — and this device picks the one it has, which is exp171's selection
  code being examined by a real relying party for the first time.

## Running it

The device half needs nobody:

```console
./drive.sh
```

Three firmwares, no finger. A `button` build that has just been asked for a
credential is sitting in its presence wait — the exact state this experiment is
about — so a client can count what it sends while nobody presses anything, and
then withdraw the request and read what comes back.

The browser half needs one person and two clicks:

```console
python3 serve.py &     # http://localhost:8174 — the origin WebAuthn will accept
./ab.sh
python3 verify.py
```

`ab.sh` does not ask anybody to press enter. It watches `transcript.json`, which
the page posts to, so *done* is a fact about a file.

### The instrument had to be rebuilt twice

The first version of this measurement asked a person to count to nine and a
half against a ten-second window. The second asked them to hold a button for
half a minute. **Both put the precision of the measurement inside a human
reflex**, and the person running it said so both times.

The third shape works: the press is **latched** at any moment in the window and
the answer leaves on `EXP174_HOLD_MS`, the board's own clock. The person only
has to press. The log prints the press and the answer as separate numbers so the
delay is never mistaken for the reflex:

```text
pressed at 2323 ms, answered at 25013 ms, 0 keepalives sent
```

At `EXP174_HOLD_MS=0` and `EXP174_KEEPALIVE=off` this firmware is exp173.

## Build inputs

| | | |
|---|---|---|
| `EXP174_UP` | `none` \| `button` | exp173's. `none` never asks and says so |
| `EXP174_KEEPALIVE` | `on` \| `off` | the arm. Default `on` |
| `EXP174_HOLD_MS` | ms | do not answer a held button before this. Default 0 |
| `EXP174_TIMEOUT_MS` | ms | how long a person who is not there has. Default 10000 |

## The key is still a test key

`DEVICE_SECRET` is thirty-two compiled-in bytes that spell
`not a secret. this is a test key`, printed at every boot with the address it
lives at. Every credential on this road is derived from it and nothing is
stored. Where a real one would come from is the
[identity road](../README.md#the-identity-road), which has not been built.

## Expected output

See [capture.txt](./capture.txt), and `browser-ab.json` for the two arms in the
form `verify.py` re-checks.
