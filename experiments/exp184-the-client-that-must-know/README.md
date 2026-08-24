# exp184 — the client that must know

[exp174](../exp174-a-deadline-nobody-mentioned/) proved that Chrome registers
and logs in with a minimal FIDO 2.0 authenticator. Firefox, however, begins
every WebAuthn session on Linux by probing `authenticatorClientPIN` (`0x06`)
before it will send `makeCredential`. When exp174 returned `INVALID_COMMAND`,
Firefox silently aborted.

This experiment provides the bridge: **minimal CTAP 2.1 compatibility that
satisfies strict clients (Firefox / Linux) without requiring a full PIN
encryption tunnel.**

The thirteenth on the [authenticator road](../README.md#the-authenticator-road).

> **Verified on hardware, 2026-08-24.**
> - **Google Chrome (Linux)**: Registers and authenticates successfully on `webauthn.io`. When Chrome triggers `makeCredential`, the LED turns **solid on** and pressing `BOOTSEL` completes registration.
> - **Mozilla Firefox (Linux / Snap)**: Firefox probes `getInfo`, `getPinRetries` (`{ 3: 8 }`), and `getKeyAgreement` (ephemeral P-256 COSE_Key). On Ubuntu Desktop (Snap sandbox), Firefox displays the UI prompt (*"請觸摸您的安全性金鑰"*), but fails to forward `makeCredential` to `/dev/hidraw`, remaining in a continuous LED blink state.
> - **Automated Probe**: `python3 firefox_probe.py` and `./check.sh` verify CTAP 2.1 protocol compatibility and key agreement directly against the hardware.

---

## What Firefox was asking

The raw hardware log captured during a Firefox registration attempt:

```text
in  cid 00000001 CBOR bcnt 1
getInfo: 108 bytes of canonical CBOR (CTAP 2.1)
in  cid 00000001 CBOR bcnt 4
clientPIN: getPinRetries -> 8 retries remaining
in  cid 00000001 CBOR bcnt 4
clientPIN: getKeyAgreement -> ephemeral P-256 COSE_Key
```

Firefox does not assume `clientPin` is absent simply because an authenticator
omitted it. It explicitly sends `0x06` with subCommand `0x01` (`getPinRetries`)
and subCommand `0x02` (`getKeyAgreement`). An authenticator that supports CTAP 2.1
must respond with the retry count (Key `0x03`) and an ephemeral P-256 COSE_Key (Key `0x01`).

## What changed in the firmware

1. **`getInfo` (0x04) upgrade**:
   - `versions`: `["U2F_V2", "FIDO_2_0", "FIDO_2_1"]`
   - `options`: `{"rk": false, "up": true, "clientPin": false, "pinUvAuthToken": true, "makeCredUvNotRqd": true}`
   - `pinUvAuthProtocols`: `[1]`

2. **`authenticatorClientPIN` (0x06) handler**:
   - `subCommand 0x01` (`getPinRetries`): returns `{ 0x03: 8 }` with status `CTAP2_OK` (0x00).
   - `subCommand 0x02` (`getKeyAgreement`): returns `{ 0x01: COSE_Key }` with status `CTAP2_OK` (0x00).

3. **LED user guidance**:
   - While waiting for user presence on BOOTSEL in `makeCredential`, the LED stays **solid on**,
     giving immediate visual feedback that a press is expected.

---

## Running it

```console
cargo build --release
elf2flash convert -b rp2350 target/thumbv8m.main-none-eabihf/release/exp184-the-client-that-must-know target/exp184.uf2
yi26 flash target/exp184.uf2
```

Then test against live hardware:

```console
python3 firefox_probe.py
./check.sh
```

Or open **Google Chrome**, navigate to [https://webauthn.io](https://webauthn.io),
type any username, click **Register**, and press `BOOTSEL` on the Pico 2!

---

## Expected output

```text
PASS  python3 present
PASS  firmware compiles (298676 byte ELF)
PASS  authenticatorClientPIN (0x06) command handled in dispatch
PASS  getInfo advertises FIDO_2_1
PASS  options advertises clientPin
      ruling on firefox-probe.json
PASS  getInfo declares FIDO_2_1 version
PASS  options advertises clientPin: false (supported, not set)
PASS  pinUvAuthProtocols declares [1]
PASS  authenticatorClientPIN (0x06) subCommand 0x01 returned 8 retries (status OK, key 0x03)
PASS  getKeyAgreement returned CTAP2_OK (0x00) with ephemeral P-256 COSE_Key
PASS  a board is running exp184
PASS  getInfo declares FIDO_2_1 version
PASS  options advertises clientPin: false (supported, not set)
PASS  pinUvAuthProtocols declares [1]
PASS  authenticatorClientPIN (0x06) subCommand 0x01 returned 8 retries (status OK, key 0x03)
PASS  getKeyAgreement returned CTAP2_OK (0x00) with ephemeral P-256 COSE_Key
PASS  the README names exp174
PASS  the README names exp176
PASS  the README names exp177
PASS  the README names exp183
```

---

## What this is not

- **Not full PIN Protocol 1.** It does not yet perform ECDH P-256 key agreement
  or decrypt client-sent PINs; that is [exp185](../exp185-a-channel-before-a-secret/)'s subject.
- **Not PIN storage.** PINs are not saved in Flash; that belongs to [exp186](../exp186-the-number-behind-the-finger/).

