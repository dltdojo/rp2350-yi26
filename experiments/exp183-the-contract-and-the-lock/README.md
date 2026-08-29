# exp183 — the contract and the lock

[exp174](../exp174-a-deadline-nobody-mentioned/) built a working CTAP2/WebAuthn
authenticator by hand, but bundled USB HID, CBOR decoding, P-256 crypto,
and static test keys directly into a single 74 KB binary.
[exp178](../exp178-the-shape-of-the-contract/) then evaluated Google OpenSK's
`Env` trait abstraction, measuring its powerful decoupling against a heavy cost:
**121,184 bytes of Flash for the engine alone and a mandatory heap allocator**.

This experiment provides the bridge: **a lightweight, zero-heap (`no_std`)
trait contract that decouples the FIDO2 engine from hardware key storage,
enabling 4 pluggable backends, paired with an inspection and verification
pipeline for RP2350 Secure Boot and Secure Lock without burning a single fuse.**

The twelfth on the [authenticator road](../README.md#the-authenticator-road).

> **Verified on hardware, 2026-08-23.** The trait abstraction layer adds
> **zero heap allocations** and compiles cleanly across all four backends:
> static test key ([exp174](../exp174-a-deadline-nobody-mentioned/)),
> Bank 8 isolated SRAM with wipe ([exp159](../exp159-a-key-that-was-never-in-flash/)),
> SRAM startup PUF ([exp181](../exp181-a-key-that-is-written-nowhere/) /
> [exp182](../exp182-where-the-wrapping-key-comes-from/)), and OTP simulation.
> `otp_audit.py` maps out the exact bit transitions for Secure Lock in dry-run
> mode, while `image_seal.py` and `bootrom_verify.py` generate and emulate
> RP2350 Block 0 Bootrom signature and AES-XIP decryption checks.


## One byte, and the crash it was hiding

> **Added and verified on hardware, 2026-08-29.** The trait contract, the four
> backends and the Secure Boot inspection are untouched. What is corrected is
> the half of this experiment that is a FIDO2 authenticator **as anybody else's
> client sees it** — which turned out never to have been driven by one.

`CTAPHID_INIT` answered `0x08` under a comment that said `CBOR`. `0x08` is
`CAPABILITY_NMSG`; the CBOR bit is `0x04`. Every other rung on this road from
[exp169](../exp169-what-it-says-it-can-do/) to
[exp188](../exp188-the-passkey-in-the-pocket/) sends `0x04 | 0x08`, and the one
experiment that sends `0x08` alone is
[exp168](../exp168-a-security-key-that-knows-nothing/) — **on purpose**, because
it has no CBOR at all. This firmware landed on the "I know nothing" value while
implementing a full authenticator.

Its own CBOR was never the problem. Asked by this repository's own client the
board answered `CTAP2_OK` and `versions: ["FIDO_2_0"]`; asked by `libfido2` it
printed `caps: 0x08 (nowink, nocbor, nomsg)` and stopped there. One client reads
the byte and the other does not.

### What the byte was hiding

Correcting it did not make the board work. It made the board **die**, inside a
second, every time — and finding out why is the point of this section.

```rust
async fn handle_cbor(...) {
    let cmd = req[0];
    let out = CBOR_BUF.init([0u8; MAX_MESSAGE]);   // once per request
```

**`StaticCell::init` panics the second time it is called.** `CHANNEL` and
`IN_PACKET` are claimed once in `run_fido_authenticator`, which is where a
`StaticCell` belongs; this one was claimed on the per-request path. So this
firmware could answer **exactly one CBOR command per boot**, and the second one
took the executor down with it.

`fido2-token -I` sends two: `authenticatorGetInfo`, then `clientPIN` for the PIN
retry count. This repository's own probe sends one per run. **Nothing here could
have found it**, and the capability byte is why: no `libfido2` client ever sent
this board a first CBOR command, so none ever sent a second. That is
[exp173](../exp173-a-client-that-is-not-ours/)'s subject arriving on the one rung
that had never been driven by somebody else's tools.

### Three trips to the bench, and what stopped the fourth

The board came back dead three times and each time needed a hand on BOOTSEL,
because this firmware had **one** `log!` call in it — the backend name, at boot —
and `panic-halt`, which stops the world in silence. *Dark* and *died* were the
same signal, which is the exact failure `AGENTS.md` asks every firmware to
design against before it needs to.

What made the fourth trip unnecessary was this repository's own toolbox, and the
sequence is worth reading as a method rather than a fix:

| added | what it ruled out |
|---|---|
| a heartbeat, two seconds apart | it stopped dead with the response, so the board was not merely idle |
| a `#[panic_handler]` that logs | replaced `panic-halt`; the line never escaped, because the log is a ring drained by a task that was no longer running |
| packet logging on both sides of every write | the getInfo response **left** — so it was not stranded in `class.write().await` |
| [`crates/breadcrumb`](../../crates/breadcrumb/)'s armed watchdog | `Hang at step 3`: past the incoming `log!`, before `handle_cbor`. And the board now **resets itself**, so every iteration after this one was free |

The note said `Hang` rather than `Fault` because the panic handler spins without
feeding the watchdog — so a panic and a hang look alike here, and the step number
is what separated them. One caveat for anybody reading a note from this
firmware: **reflashing also reads as `Hang at step 1`**, because the flash
interrupts the loop where it waits.

### Verified

```console
$ time fido2-token -I /dev/hidraw4
caps: 0x0c (nowink, cbor, nomsg)
version strings: FIDO_2_0
real    0m0.107s
```

Five consecutive runs, all answered; the board stayed up; `./check.sh` passes
its twenty-two checks. `CAPABILITIES` is a named constant now and `check.sh`
fails if it or the `resp[16]` that uses it ever drifts apart again.


---

## Part 1: The Contract — Lightweight, Zero-Heap Hardware Abstraction

In `src/contract.rs`, the FIDO2 business logic is completely decoupled from
hardware specifics:

```rust
pub trait KeyBackend {
    fn name(&self) -> &'static str;
    fn derive_credential_key(
        &mut self,
        rp_id_hash: &[u8; 32],
        cred_random: &[u8; 32],
        counter: u32,
    ) -> Result<SigningKey, KeyError>;
    fn sign_credential_id(
        &mut self,
        cred_random: &[u8; 32],
        rp_id_hash: &[u8; 32],
    ) -> Result<[u8; 16], KeyError>;
    fn verify_credential_id(
        &mut self,
        cred_random: &[u8; 32],
        rp_id_hash: &[u8; 32],
        tag: &[u8; 16],
    ) -> bool;
    fn sign(&mut self, key: &SigningKey, digest: &[u8; 32]) -> Result<Signature, KeyError>;
    fn wipe(&mut self);
}

pub trait PersistStore {
    fn get_signature_counter(&self) -> u32;
    fn increment_counter(&mut self) -> u32;
}
```

The core protocol loops in `src/main.rs` (`handle_cbor`, `run_fido_authenticator`)
are written generically over `<K: KeyBackend, P: PersistStore>`. Switching
where secrets come from requires changing only the instantiated backend type:

| Backend | Location of Master Secret | Hardware Protection | Reference |
|---|---|---|---|
| **`TestKeyBackend`** | Static Flash constant | None (extractable via `forge.py`) | [exp174](../exp174-a-deadline-nobody-mentioned/), [exp175](../exp175-the-secret-is-the-file/) |
| **`Bank8SecureBackend`** | SRAM Bank 8 (`0x2008_0000`) | Non-secure reads fault; wiped after signing | [exp159](../exp159-a-key-that-was-never-in-flash/), [exp163](../exp163-how-long-is-a-secret-in-the-open/) |
| **`PufReconstructedBackend`** | Reconstructed at power-on | Key absent from image; reconstructed from silicon cells | [exp181](../exp181-a-key-that-is-written-nowhere/), [exp182](../exp182-where-the-wrapping-key-comes-from/) |
| **`OtpSimulatedBackend`** | OTP Row 0x000 + AES-XIP | Protected by RP2350 Secure Lock hardware | [exp154](../exp154-somewhere-to-put-a-key/), this experiment |

---

## Part 2: The Lock — RP2350 Secure Boot & Secure Lock without Burning Fuses

A major dilemma in embedded security education is that **burning OTP fuses is irreversible**:
once a developer burns `CRIT1` or `CRIT2` with a test key, that development board
is permanently locked to that key and cannot be reused for general development.

This experiment solves that dilemma with a **non-destructive, three-stage inspection pipeline**:

### 1. OTP Audit & Dry-Run Fuse Mapping (`otp_audit.py`)
Reads the chip's 4096 OTP rows (as explored in [exp154](../exp154-somewhere-to-put-a-key/))
and calculates the exact fuse programming plan needed to lock down the device:
- **`BOOTKEY0..3` (Rows `0x000`–`0x007`)**: 256-bit SHA-256 hash of the authorized signing public key.
- **`AES_XIP_KEY` (Rows `0x008`–`0x00f`)**: 256-bit AES key for hardware flash decryption.
- **`CRIT1` (Row `0x010`)**: Sets bit 0 (`SECURE_BOOT_ENABLE`) to force Bootrom signature verification.
- **`CRIT2` (Row `0x011`)**: Sets bit 1 (`DEBUG_DISABLE`) and bit 2 (`NONSECURE_OTP_DISABLE`) to permanently lock SWD and Non-secure OTP access.

### 2. Standard Image Sealing (`image_seal.py`)
Packs the firmware binary into a genuine RP2350 Secure Boot container:
- Generates **Block 0 (IMAGE_DEF: `0xffffded3`)** containing public key coordinates and ECDSA P-256 signature.
- Simulates hardware AES-256-CTR encryption over the payload.
- Appends the terminator magic (`0xab123579`).

### 3. Bootrom Verification Emulation (`bootrom_verify.py`)
Emulates the exact algorithmic checks performed by the RP2350 ROM at boot:
1. Validates Block 0 magic and structure.
2. Compares public key hash against the OTP `BOOTKEY` record.
3. Decrypts AES-XIP payload stream.
4. Computes SHA-256 digest and verifies ECDSA P-256 signature (as measured in [exp166](../exp166-whose-firmware-will-it-accept/)).
5. Validates vector table entry point alignment.

---

## Running it

```console
# 1. Run the interactive walkthrough
./run.sh

# 2. Audit OTP layout and view the Secure Lock dry-run plan
python3 otp_audit.py

# 3. Seal an image and emulate Bootrom verification
python3 image_seal.py --output target/exp183-sealed.bin
python3 bootrom_verify.py target/exp183-sealed.bin

# 4. Run automated test suite
./check.sh
```

---

## Expected Output

```text
PASS  python3 present
PASS  firmware compiles default backend (74280 byte ELF)
PASS  contract backend 'bank8' compiles clean
PASS  contract backend 'puf' compiles clean
PASS  contract backend 'otp_sim' compiles clean
PASS  contract.rs defines standalone trait interface
PASS  KeyBackend and PersistStore traits are defined
PASS  FIDO2 core engine is generic over KeyBackend contract
PASS  otp_audit.py runs and evaluates OTP map (dry-run)
PASS  image_seal.py generates valid Block 0 sealed image
PASS  bootrom_verify.py emulates and confirms Bootrom acceptance
PASS  transcript record present
PASS  a board is running exp183
PASS  the README names exp154
PASS  the README names exp159
PASS  the README names exp166
PASS  the README names exp174
PASS  the README names exp178
PASS  the README names exp181
PASS  the README names exp182
```
