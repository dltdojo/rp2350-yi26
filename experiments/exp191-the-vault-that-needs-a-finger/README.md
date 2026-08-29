# exp191 — the vault that needs a finger

[exp189](../exp189-the-same-salt-twice/) got a **key** out of a board — the same
thirty-two bytes every time, and only after somebody pressed. This is what the
key is for: a CLI's credentials that are ciphertext until a board somebody
pressed hands over the bytes that open them.

> **Not verified on hardware.** The half that needs no board is: a wrong key
> **raises** rather than producing rubbish, and the token is not findable in the
> ciphertext. The four presses have not been run. See
> [Expected output](#expected-output).

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

Not captured yet — the four presses have not been run. This section stays empty
until they have, and is filled in from a real transcript rather than from what
the code should do.

The half that has run, and needs no board:

```text
PASS  a directory seals
PASS  the token is not readable in the ciphertext
PASS  and the right key gets exactly what went in
PASS  a wrong key fails rather than producing rubbish — GCM's tag, not a policy
PASS  and leaves nothing behind
```

## Next

The browser half. WebAuthn's `prf` extension is exp189's `hmac-secret` with a
different face, and [exp174](../exp174-a-deadline-nobody-mentioned/) already
proved a browser registers with this board — so a local page could derive the
same key and open the same vault, which would make the two clients a comparison
rather than an alternative. It needs a person and a browser, which is why it is
not here.
