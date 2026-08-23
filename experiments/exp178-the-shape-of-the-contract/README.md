# exp178 — the shape of the contract

[exp168](../exp168-a-security-key-that-knows-nothing/) through
[exp174](../exp174-a-deadline-nobody-mentioned/) built a CTAP2 authenticator by
hand, three commands at a time. This one asks what it would have cost to not:
it pulls [OpenSK](https://github.com/google/OpenSK)'s `opensk` library in behind
its `Env` trait, writes the smallest adapter the compiler will accept, and then
runs the same engine on the host and rules on
[exp176](../exp176-the-same-question-of-two-devices/)'s list of what this board
could not do.

The tenth on the [authenticator road](../README.md#the-authenticator-road), and
the first that measures somebody else's answer to the road's own question.

> **Verified on host, 2026-08-23.** No board, no USB, nobody in the room. The
> adapter is **25 methods and 10 associated types** against a trait that demands
> 43 signatures, and it links for `thumbv8m.main-none-eabihf` on **stable**
> Rust. The engine behind it costs **121,184 bytes of flash** — 1.6× exp174's
> entire firmware — and closes **all ten** of the differences exp176 classified
> as code, including two that are asked for rather than read off. The one
> exp176 called certification is not closed, and no amount of somebody else's
> code closes it.

> **Not vendored, and not ours.** `./setup.sh` clones OpenSK at a pinned commit
> into `upstream/`, which is git-ignored; nothing of theirs is committed here.
> The adapter in `stub/`, the driver in `driver/` and the two Python scripts are
> this repository's own code, written against their API. Both projects are
> Apache-2.0, which is what makes the reuse legal; `check.sh` asserts all three
> obligations that licence imposes.

## What was already known, and what was not

The road's own opening paragraph cites prior work on this chip: a Rust and
Embassy authenticator on an RP2350 that registered and authenticated against
`webauthn.io` using an existing CTAP2 library rather than a hand-written engine.
**So "does this work" was not the question.** It was answered before this
repository existed, and an experiment that presented it as a discovery would be
spending a reader's attention on something already closed.

What was not known is the shape of the bargain — how wide the trait is, how much
of its width is free, what the engine costs in flash on this part, and whether
it closes the specific gaps exp176 measured against a commercial key. Those are
numbers, they are checked here rather than asserted, and none of them was
written down anywhere this repository could point at.

## Half one: what the compiler demands

`stub/src/main.rs` is the measurement. Every method in it exists because the
build failed without it.

| trait | must write | free | feature-gated | associated types |
|---|---:|---:|---:|---:|
| `Rng` | 0 | 1 | 0 | 0 |
| `UserPresence` | 3 | 0 | 0 | 0 |
| `Clock` | 2 | 0 | 1 | 1 |
| `HidConnection` | 2 | 0 | 0 | 0 |
| `Persist` | 4 | 28 | 15 | 0 |
| `KeyStore` | 7 | 0 | 0 | 0 |
| `Customization` | 16 | 0 | 5 | 0 |
| `Crypto` | 0 | 0 | 0 | 7 |
| `Env` | 9 | 2 | 1 | 10 |
| **total** | **43** | **31** | **22** | **18** |

Counted by `obligations.py` from the pinned source, not typed in — and by
reading braces rather than by grep, because several of these signatures run to
four lines and counting only the ones that fit on one undercounts
`UserPresence` by exactly the method that matters.

**Forty-three demanded, twenty-five written.** The difference is three escape
hatches, and finding them is most of what this experiment is:

- **`impl Helper for StubEnv {}`** — one empty line. `Helper` is a marker trait
  with no methods, and `impl<T: Helper> KeyStore for T` gives anything that says
  it the whole key store: credential wrapping and unwrapping, the
  per-credential HMAC secret, PIN hash encryption and decryption. Seven methods,
  and the ones that decide what a credential ID *is*.
- **`DEFAULT_CUSTOMIZATION`** — a `const`. Twenty-one policy questions with
  upstream's answers already filled in. Accepting them is one field
  initialiser, and each one is still a decision this device would announce to
  every relying party it ever meets.
- **`type Crypto = SoftwareCrypto`** — the `software_crypto` feature. Seven
  associated types and the fifteen methods under them, from `p256`, `sha2`,
  `hmac`, `hkdf`, `aes` and `cbc`.

What is left after those is the part no library can guess, and **every one of
the six already exists in this repository**, which is the finding this
experiment was proposed for:

| obligation | methods | what this repository already has |
|---|---:|---|
| `Rng` (via `rand_core::RngCore`) | 4 | [exp109](../exp109-hardware-trng/)'s TRNG — and exp174's warning about `sample_count` |
| `UserPresence` | 3 | [exp171](../exp171-a-credential-nobody-asked-for/)'s BOOTSEL wait, [exp174](../exp174-a-deadline-nobody-mentioned/)'s keepalive |
| `Clock` | 2 | `embassy-time`, running since exp168 |
| `Write` | 1 | [`crates/usb-log`](../../crates/usb-log/) over the CDC interface |
| `Persist` | 4 | [exp145](../exp145-a-drive-of-our-own/) writes flash from firmware; [exp157](../exp157-a-note-for-the-next-boot/) keeps a note across a reset |
| `HidConnection` | 2 | [exp168](../exp168-a-security-key-that-knows-nothing/)'s CTAPHID, with [exp128](../exp128-reassemble-by-hand/)'s packet arithmetic |
| `Env` itself | 9 | wiring, and nothing else |

`Persist` is the one worth staring at. **Four methods — `find`, `insert`,
`remove`, `iter` — and it is a key-value store, nothing more.** Twenty-eight
CTAP-level operations sit on top of them: credentials, the PIN retry counter,
the large-blob array, the signature counter. The obligation this road would
have assumed was the expensive one is the cheapest thing in the table.

### Two things the contract costs that are not methods

**A heap.** `Env` hands back `alloc::vec::Vec`, and `Persist::iter` returns a
`Box<dyn Iterator>`. There is no feature that turns this off. Every experiment
from exp168 to exp174 hand-rolled CTAP2 with no allocator at all — and
[`crates/cbor`](../../crates/cbor/) refuses to allocate by construction, which
`check.sh` there enforces — so `#[global_allocator]` in `stub/src/main.rs` is
the first one on this road. It is checked for, so that it cannot be removed as
tidying.

**Stable is enough.** Prior work on this chip built the same library on a
nightly toolchain, and `opensk` asks for `subtle`'s feature named `nightly`,
which reads like a requirement and is not one. Checked rather than assumed:
`cargo check --target thumbv8m.main-none-eabihf --no-default-features --features
software_crypto` on **stable 1.94.1** finishes clean. The crate's manifest also
declares `openssl` among its build dependencies and has no `build.rs` to use it,
so no system OpenSSL is needed either.

## What the engine costs in flash

The same crate builds twice — `--no-default-features` removes the engine and
keeps the heap, the entry point and the panic handler — so the difference is the
engine and nothing else:

```text
  with engine     123,404 bytes
  without engine    2,220 bytes
  the engine      121,184 bytes
```

For scale: exp174's **entire firmware** — a hand-written three-command CTAP2
engine, Embassy, the USB stack, a CDC log, an LED and P-256 — is 74,680 bytes.
Full CTAP 2.1 with software crypto is 1.6× that on its own, before a single byte
of USB.

That number has a consequence this repository has already built against.
[exp142](../exp142-two-images-one-version/)'s A/B slots are sixteen sectors —
64 KiB — each, and [exp145](../exp145-a-drive-of-our-own/) installs into one of
them. **An image carrying this engine does not fit in either slot.** It is a
geometry, not a wall: exp145's own troubleshooting table already names widening
the slots as the fix, and a 4 MiB part has the room. But an update road built
around 64 KiB slots and an authenticator road built around OpenSK do not meet
without somebody changing a partition table.

### The first version of this measurement measured nothing

With every stub returning a compile-time constant, LTO propagated them through
the whole engine and 23,361 lines of CTAP came out as **1,852 bytes**. The
symbol table said what had happened: one `drop_in_place` and some elliptic-curve
scaffolding survived, and nothing else did. A stub is *knowable* in a way a real
implementation is not, and an optimiser will use that.

Every stub now answers through `core::hint::black_box`, and so does the packet
handed to `process_hid_packet`, so no command handler can be proved unreachable.
`check.sh` fails if the measured difference falls under 100 KiB — the shape the
mistake had, rather than the mistake itself.

## Half two: the engine, running, against exp176's list

`driver/` builds the same library for the host with `std`, which brings
OpenSK's own `TestEnv` — all six obligations supplied. `Ctap::process_hid_packet`
takes a 64-byte CTAPHID report and returns 64-byte reports, so the whole device
fits inside a process and is spoken to in exactly the bytes exp168 put on a
wire, packet splitting and all.

`closes.py` reads the ten differences **out of exp176's own
`comparison.json`** and rules on each. If exp176's categorisation changes and
this does not, `check.sh` fails rather than quietly disagreeing.

| exp176 said the board lacked | closed? | on what evidence |
|---|---|---|
| `U2F_V2` | yes | upstream's `ctap1` feature |
| `FIDO_2_1_PRE` | yes | and not the preview string — this engine claims `FIDO_2_1` |
| `credProtect` | yes | announced as an extension |
| `hmac-secret` | yes | announced as an extension |
| `rk` | yes | **a resident credential was actually made** — 260 bytes, status 0 |
| `clientPin` | yes | announced — and it is the exact surface the road cut on purpose |
| `credentialMgmtPreview` | yes | as `credMgmt`, the full command |
| no algorithms advertised | yes | field 10, two entries |
| `eddsa` | yes | **an Ed25519 credential was actually made** — 428 bytes, status 0 |
| `pin_protocols=1` | yes | field 6 offers 2, 1 |

Two of the ten are asked for rather than read off, because
[exp169](../exp169-what-it-says-it-can-do/) is the experiment that made
announcing and having into different claims. The other eight are read from
`getInfo` and are announcements; **this experiment does not check that the other
eight work**, and says so here rather than in a footnote.

The three exp176 called **policy** are accounted for and not closed, because
they are not the kind of thing that closes: two of them — `max_cred_count_list`
and `pin_retries` — are among `Customization`'s twenty-one, which is the
contract saying out loud that they are decisions. The third, `max_cred_len`, is
not a `Customization` method at all: it falls out of how the key store wraps a
credential, and this engine reports 241 where the commercial key reported 128.

And the one exp176 called **certification**:

```text
  aaguid: 00000000000000000000000000000000
```

**Sixteen zero bytes, exactly like exp174's board.** OpenSK offers batch
attestation as a mechanism — a certificate and a key you supply — and a
mechanism is not a certification. [exp175](../exp175-the-secret-is-the-file/)'s
gap is untouched: a secret the image carries is a secret anyone with the image
has, and swapping the engine changes nothing about that.

## A reader of ours refused a real authenticator's bytes

exp169's host-side CBOR reader — the canonical-only one, copied forward through
exp170, exp171 and exp172 — **rejects OpenSK's `getInfo` at the first text map
key**, with "a map key that is not an unsigned integer". The bytes are not
wrong. CTAP 2.1 defines `options` and `algorithms` with string keys, and the
reader is narrower than the protocol because the device it was written against
never emitted one.

[exp170](../exp170-a-map-somebody-else-wrote/) wrote down that whether a real
browser sends something its strict reader rejects was untested. This is the
mirror image and a smaller claim: a real *authenticator* emits something a
strict reader **on the host side** rejects. The firmware reader in
[`crates/cbor`](../../crates/cbor/) is different code and accepts text keys —
while explicitly declining to check their ordering, in a comment that says so.
This experiment's reader keeps exp169's strictness and adds the missing rule:
text keys sort after integer ones, by length and then by bytes. OpenSK's
`getInfo` passes it. It began inside `closes.py` and now lives in
[`../cbor.py`](../cbor.py), because exp177 met the same limit against a third
party's firmware on the same day and two copies of a reader written to stop
copies drifting would have been a poor joke. Nothing before exp177 imports it:
the four older readers stay as they are.

## Where this does not go

- **Nothing here was flashed.** `stub/` links for the board's target and is
  never put on a board; half its methods return errors. It answers what the
  contract demands, not what a device does.
- **It is not a security key and must not be read as one.** `StubRng` returns
  zeros and asserts `CryptoRng` while doing it. That is the one lie in the file
  and it is only safe because no image here is ever flashed.
- **The flash figure is this build's**: `opt-level = "s"`, LTO, one codegen
  unit, `software_crypto` and nothing else enabled, on stable 1.94.1. A build
  with `ctap1`, `config_command` and Ed25519 turned on — the driver's feature
  set — is larger, and nobody measured how much.
- **Eight of the ten closures are announcements.** See above.
- **The comparison to exp174's 74,680 bytes is not engine-to-engine.** exp174's
  image contains a USB stack and a CDC log that the stub does not; the stub
  contains an engine that exp174's does not. Both numbers are stated for what
  they are.
- **This says nothing about whether adopting OpenSK is the right call.** The
  road's open question — is a hand-written engine right past the second
  experiment — now has a size, an obligation list and a licence attached to one
  of its answers. It still has to be decided by whoever reaches it.

## Running it

```console
./setup.sh          # clone the engine at the pinned commit — the network, once
./check.sh          # everything: both builds, the engine, exp176's list
python3 obligations.py    # just the contract's shape
```

No board is involved at any point, and nothing here needs a person.

## Expected output

```text
PASS  python3 present
PASS  cargo present
PASS  the engine is cloned (./setup.sh)
PASS  the clone is at the commit setup.sh pins (b3b16fb3af12bd8249b9e2a6b4b5869d9036ccda)
PASS  no upstream file is committed to this repository
PASS  obligation 1 of 3: upstream's licence travels with its code
PASS  obligation 2 of 3: this experiment's own files carry the same licence
PASS  obligation 3 of 3: the README says what is ours and what is theirs
PASS  the board's target is installed
PASS  the stub declares stable Rust
      building both arms of the stub (this is the measurement) ...
PASS  the stub meets Env and links for the board's target
PASS  the same crate builds with no engine in it
      with engine 123404 bytes, without 2220, engine 121184
PASS  full CTAP 2.1 costs 121184 bytes of flash on this chip
PASS  every stub answers through black_box, so nothing is folded away
PASS  the adapter carries a global allocator — the contract requires one
PASS  all six obligations name the experiment that already implements them
PASS  the contract's shape is counted from the pinned source
PASS  the README carries the totals row
PASS  the README's 43 demanded signatures are what the source says
PASS  and its 31 free ones
PASS  and its 18 associated types
PASS  the adapter is 25 methods and 10 associated types
PASS  and the README says the same numbers
      running the engine in this process ...
PASS  the engine answers CTAPHID in a host process, with no board
PASS  OpenSK's getInfo is canonical CBOR by this repository's own reader, text map keys and their ordering included
PASS  U2F_V2: closed — the CTAP1/U2F path, behind upstream's `ctap1` feature
PASS  FIDO_2_1_PRE: closed — and not the preview string: this engine claims FIDO_2_1
PASS  credProtect: closed — announced as an extension
PASS  hmac-secret: closed — announced as an extension
PASS  rk: closed — announced, and a resident credential was actually made — 260 bytes of attestation object, status 0
PASS  clientPin: closed — announced; note this is the exact surface the road cut on purpose, and the one that trips Android's strict parser
PASS  credentialMgmtPreview: closed — announced as `credMgmt`, the full command rather than the preview
PASS  (no algorithms advertised): closed — field 10 is present with 2 entry/entries
PASS  eddsa: closed — announced, and an Ed25519 credential was actually made — 428 bytes, status 0
PASS  pin_protocols=1: closed — field 6 offers 2, 1, in that order
PASS  max_cred_count_list=8: one of the twenty-one Customization methods
PASS  max_cred_len=128: not a Customization method: it falls out of how the key store wraps a credential, so a build changes it by changing the format and not by setting a number — this engine reports 241
PASS  pin_retries=8: one of the twenty-one Customization methods; not in getInfo, because it is answered by clientPIN
PASS  the AAGUID is still all zeroes: the one difference exp176 called certification is not closed by code
PASS  every one of exp176's 10 code differences was ruled on
PASS  all 10 of exp176's code differences are closed by somebody else's engine
PASS  and the one exp176 called certification is not — no amount of code closes it
PASS  the README rules on exp176's list rather than a list of its own
PASS  the README ties the uncloseable gap to exp175
```

`./setup.sh` is the only step that touches the network, and it prints one line.
`check.sh` builds three binaries — two arms of the stub for the board's target
and the driver for the host — so the first run takes a minute or two and the
next takes seconds.
