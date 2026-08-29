# exp191 — the vault that needs a finger

[exp189](../exp189-the-same-salt-twice/) got a **key** out of a board — the same
thirty-two bytes every time, and only after somebody pressed. This is what the
key is for: a CLI's credentials that are ciphertext until a board somebody
pressed hands over the bytes that open them.

> **Verified on hardware, 2026-08-29.** Pressed, the CLI comes up logged in as
> the user whose credentials were sealed, and the decrypted copy is wiped on the
> way out. With the board right there and **nobody pressing**, the wrapper
> refuses in one line, the CLI never runs, and nothing is decrypted on the way
> to refusing. A wrong key **raises** rather than opening into rubbish — that
> half needs no board at all. And the leaky subject was caught: its redirection
> worked perfectly and its token was still readable in `$HOME/.cache`.
> See [Expected output](#expected-output).

The second of the two rungs this pair was split into, and the one whose subject
is a product rather than a measurement.

## The claim

> **Without the board, a CLI has no credentials at all — and with it, nothing is
> written to a disk.**

Two halves, and only one of them is about the board:

- **the lock** is `AES-256-GCM` keyed by exp189's thirty-two bytes. A wrong key
  does not open the vault into garbage that a caller carries on with; it raises,
  because GCM has a tag. That is cryptography rather than control flow, and
  `check.sh` proves it **with no board attached**.
- **the wrapper** decrypts into a tmpfs, points the CLI at it with an
  environment variable, runs it, and wipes on every exit including a `Ctrl-C`.

## Why the subject is a CLI nobody ships

`gh`, `aws`, any real tool: each would make this a client of somebody else's
service, with somebody else's release schedule and somebody else's config
format. [exp177](../exp177-the-same-chip-somebody-elses-decisions/) pins a third
party's binary by SHA-256 and that works **because the binary is offline** — a
tool that authenticates against a network cannot be pinned at all. **An
experiment that cannot be re-run in five years is not an experiment.**

And what is under test was never the CLI. It is the chain — redirect, decrypt,
run, wipe — so the CLI is the load, and a load written here removes a variable
rather than adding one. That is [exp168](../exp168-a-security-key-that-knows-nothing/)
building a security key with no cryptography in it, for the same reason.

### The three properties a real CLI must have

Nothing here tests a real one, so what is owed instead is the list to check
yours against:

1. **All of its authentication state is in one directory.** Not split across a
   keyring, a registry and a dotfile.
2. **That directory's location comes from an environment variable**, and the
   variable wins over the home directory.
3. **It caches nothing anywhere else.** This is the one you have to **measure**,
   not believe — and [`mock-cli-leaky.sh`](./mock-cli-leaky.sh) is what measuring
   it looks like.

## Two subjects, because one would have shipped a broken wrapper

`mock-cli-leaky.sh` differs from `mock-cli.sh` by three lines: it also copies
the credentials to `$HOME/.cache`. Not malice — a session cache, which is what
real tools do.

**Nothing about the redirection is broken in that arm.** The config directory is
honoured perfectly, the wrapper wipes exactly what it decrypted, and the secret
still ends up somewhere nobody wipes. So *"the redirection worked"* and
*"nothing was left behind"* are **two** assertions, and a wrapper tested only
against the honest subject would pass one and ship.

## The client is this repository's own

exp189 is driven by `libfido2` on purpose: the point there is that **somebody
else's tool** accepts this board. Here the point is the opposite — a chain that
still runs in five years — so the `hmac-secret` request is built by
[`experiments/ctap_client.py`](../ctap_client.py), which is this repository's,
shared for the same reason [`crates/ctap`](../../crates/ctap/) is shared on the
firmware side. `python3` and `cryptography` are the whole dependency list.

That is a smaller claim than it sounds, and worth saying plainly: `cryptography`
is still somebody else's package. It is offline, widely available and stable in
these primitives, which is a different kind of dependency from a service client —
but "zero external dependencies" would be false and is not claimed.

## What this does not establish

- **That the secret is hidden while it is in use.**
  [exp163](../exp163-how-long-is-a-secret-in-the-open/) measured that and it
  applies unchanged: for as long as the CLI runs, the token is plaintext in a
  tmpfs and in that process's memory. What is honestly claimable is *it never
  touches a disk*, and the run measures that rather than asserting it. "Zero
  trace" would be a lie.
- **That the board is that board.** The credential ID binds the key to the
  device that made it — exp172's tag is recomputed and a credential from
  elsewhere derives nothing — but nothing here tests a second board, because
  there is only one.
- **Anything about a real CLI.** See the three properties above.
- **That this is a way to protect real credentials.** Every key in this
  repository is a test key.

## Running it

Needs 2 — **four solid-LED windows, and every one of them means press.** There
is no case here that must not be pressed: exp189 learned that a solid LED may
only ever mean one thing, and its case that must not be answered lives in its own
script. A missed press costs one extra window rather than the run.

```console
./run.sh        # seals, opens, and measures what is left behind
./check.sh      # rules on the capture, and on the half that needs no board
```

The board must be running exp189 — either arm. `./run.sh` leaves `vault.bin`
behind, which is the point: it is safe to leave lying around.

## Expected output

`./run.sh`, four presses:

```text
-- sealed --
vault.bin 10268 bytes
salt, in the clear: TJdL+JmpSgkEtV1w3T3nWD86FZct9MyNGqt8Sq3cmRY=
a token anywhere in the vault? 0

-- no key --
cryptography.exceptions.InvalidTag
did a wrong key produce a directory? no

-- honest --
>>> running: MOCKCLI_CONFIG_DIR=/run/user/1000/exp191.DrWTwz ./mock-cli.sh whoami
[mock-cli] logged in as alice
[mock-cli] read from /run/user/1000/exp191.DrWTwz/auth.json
>>> wiped /run/user/1000/exp191.DrWTwz

-- leaky --
[mock-cli-leaky] wrote credentials to /run/user/1000/exp191.TyRXcw/auth.json
>>> wiped /run/user/1000/exp191.TyRXcw
left in $HOME/.cache: yes
and the token is readable there: 1

-- residue --
exp191 directories left in the runtime dir: 0
token findable anywhere under it: 0
```

`./nopress.sh`, with the board left alone:

```text
-- nobody pressed --
wrapper exit: 1
no key, so no vault. The board is the whole lock.
did the CLI run anyway? 0
decrypted directories left behind: 0
```

And `verify.py` ruling on the pair — fourteen rules, of which the two that carry
the weight are that a wrong key **raises**, and that the leak was **caught**:

```text
PASS  the config directory sealed into a vault
PASS  and the token is not findable in the ciphertext
PASS  the salt sits beside it in the clear, which is what a salt is
PASS  **a wrong key fails rather than producing rubbish** — AES-GCM's tag, not a policy
PASS  with the board present and nobody pressing, the wrapper refused
PASS  and it said why, in one line, rather than failing somewhere further down
PASS  and the CLI never ran at all
PASS  and nothing was decrypted onto the tmpfs on the way to refusing
PASS  pressed, the CLI knows itself — the credentials really were the ones sealed
PASS  and the decrypted copy was wiped on the way out
PASS  the leaky CLI really did leak, so this arm tests something
PASS  **and the token is readable in what it left** — the redirection worked perfectly and the secret still escaped
PASS  no decrypted directory survives the run
PASS  and the token is nowhere under the runtime directory
```

## Two things it cost, and the second is a lesson this repository had already paid for

- **An extraction is not finished until something runs it.**
  [`ctap_client.py`](../ctap_client.py) was lifted out of exp188's probe and
  reached a board twice with an import left behind — `default_backend`, then
  `hmac`. Each time it died in **0.3 seconds** while a retry loop above it
  reported *"window closed — press BOOTSEL"*, and somebody stood at the board
  pressing a button at a script that was never going to ask. It has a
  `--selftest` now, thirteen assertions over every pure function in it, and
  `check.sh` runs it. A retry that cannot tell a missed press from a broken
  client spends a person's time on the wrong thing, so both scripts now refuse
  to retry a failure that took under five seconds.
- **A solid LED means press. Always.** This run had a case that must not be
  pressed, printed *"DO NOT PRESS for this one"* to a terminal nobody is sitting
  at, and lit the same LED as the four that must be. A person pressing at every
  solid light — which is what they were told, correctly — answered it, and the
  wrapper opened the vault without a finger being the reason. exp189 moved its
  own no-press case out for exactly this after a key came out twice; **this is
  the second time**, and the case now lives in [`./nopress.sh`](./nopress.sh),
  which needs nobody.

## Next

The browser half. WebAuthn's `prf` extension is exp189's `hmac-secret` with a
different face, and [exp174](../exp174-a-deadline-nobody-mentioned/) already
proved a browser registers with this board — so a local page could derive the
same key and open the same vault, which would make the two clients a comparison
rather than an alternative. It needs a person and a browser, which is why it is
not here.
