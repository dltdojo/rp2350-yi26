<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 rp2350-yi26 contributors -->

# exp187 — The Three Taps and the Reset

## Question

Can an RP2350 enforce the CTAP 2.1 Authenticator Reset (`authenticatorReset` 0x07) specification — restricting factory reset to the first 10 seconds of power-on, rejecting late attempts with `CTAP2_ERR_NOT_ALLOWED` (`0x30`), wiping configured PINs and rotating the master credential wrapping salt — while simultaneously supporting built-in on-device physical gesture User Verification (`options: { "uv": true }`, triple-tap cadence, and `getPinUvAuthTokenUsingUv` 0x06)?

## Background & Lineage

- **[exp174](../exp174-a-deadline-nobody-mentioned)** verified CTAP 2.0 WebAuthn registration and assertion.
- **[exp176](../exp176-the-same-question-of-two-devices)** established CTAPHID keepalive packets during presence polling.
- **[exp177](../exp177-the-same-chip-somebody-elses-decisions)** proved CTAPHID channel timeouts and cancellation semantics.
- **[exp184](../exp184-the-client-that-must-know)** exposed `pinUvAuthProtocols: [1]` and handled `getPinRetries` (0x01).
- **[exp185](../exp185-a-channel-before-a-secret)** implemented PIN Protocol 1 ECDH P-256 key agreement and AES-256-CBC encrypted tunnel.
- **[exp186](../exp186-the-number-behind-the-finger)** implemented the stateful CTAP 2.1 PIN lifecycle and `pinUvAuthToken` issuance with `FLAG_UV` (`0x04`).

`exp187` completes the device lifecycle and built-in UV modalities: physical factory reset with a power-on security interlock and on-device triple-tap gesture verification.

## Implementation Architecture

```
                    +--------------------------------------+
                    |          Device Boot (t = 0)         |
                    |         Record BOOT_TIMESTAMP        |
                    +-------------------+------------------+
                                        |
                 +----------------------+----------------------+
                 |                                             |
           t <= 10 seconds                               t > 10 seconds
                 |                                             |
                 v                                             v
    +---------------------------+                +---------------------------+
    |  authenticatorReset(0x07) |                |  authenticatorReset(0x07) |
    |  -> Clears PIN (is_set=0) |                |  -> REJECTED              |
    |  -> Resets retries = 8    |                |  -> Returns 0x30          |
    |  -> Rotates DEVICE_SALT   |                |     (CTAP2_ERR_NOT_ALLOWED|
    |  -> Returns CTAP2_OK (0x0)|                +---------------------------+
    +---------------------------+
```

### 1. 10-Second Power-On Reset Interlock
CTAP 2.1 Section 6.4 mandates that factory reset (`authenticatorReset` `0x07`) MUST only be permitted immediately following power-on / boot.
- If `boot_time.elapsed() <= 10s`, `authenticatorReset` executes:
  - Resets `PinState` (`is_set = false, retries = 8, active_token = None`).
  - Rotates `device_salt` with fresh TRNG entropy (permanently invalidating all previously minted credentials).
  - Returns `CTAP2_OK` (`0x00`).
- If `boot_time.elapsed() > 10s`, the reset request is rejected with `CTAP2_ERR_NOT_ALLOWED` (`0x30`), preventing malware from maliciously clearing credentials while the user is away.

### 2. On-Device Gesture UV (Triple-Tap)
In addition to PIN authentication, the RP2350 advertises built-in UV support:
- `options: { "uv": true, "pinUvAuthToken": true }`.
- `getPinUvAuthTokenUsingUv` (subcommand `0x06` under `authenticatorClientPIN`): Monitors the BOOTSEL line for 3 distinct press-release transitions within 3 seconds. Upon recognition, generates and issues an encrypted 32-byte `pinUvAuthToken`.
- `makeCredential` / `getAssertion` with `uv: true`: Sets `FLAG_UV` (`0x04`) in `authData`.

## Expected Output

Running `./check.sh` on Ubuntu against a connected Pico 2:

```
PASS  python3 present
PASS  firmware compiles (302456 byte ELF)
PASS  authenticatorReset (0x07) command handled in dispatch
PASS  10-second power-on reset window interlock enforced
PASS  on-device triple-tap gesture UV implemented
PASS  getPinUvAuthTokenUsingUv (0x06) handled
      ruling on gesture-reset-probe.json
PASS  getInfo advertises uv: true (Built-in UV supported)
PASS  initial clientPin is false
PASS  setPIN succeeded and clientPin flipped to true
PASS  getPinUvAuthTokenUsingUv (0x06) issued 32B pinUvAuthToken via on-device gesture UV
PASS  makeCredential with gesture UV succeeded with FLAG_UV (0x04)
PASS  authenticatorReset (0x07) within 10s power-on window succeeded with CTAP2_OK (0x00)
PASS  post-reset state verified (clientPin wiped to false, retries reset to 8)
PASS  pre-reset credentials invalidated after reset (salt rotated, CTAP2_ERR_NO_CREDENTIALS)
PASS  authenticatorReset (0x07) sent >10s after boot correctly rejected with CTAP2_ERR_NOT_ALLOWED (0x30)
PASS  a board is running exp187
PASS  the README names exp174
PASS  the README names exp176
PASS  the README names exp177
PASS  the README names exp184
PASS  the README names exp185
PASS  the README names exp186
```

Running `python3 gesture_reset_probe.py`:

```json
{
  "device": "/dev/hidraw5",
  "initial_uv_option_is_true": true,
  "initial_client_pin_is_false": true,
  "set_pin_ok": true,
  "post_set_pin_client_pin_is_true": true,
  "gesture_uv_token_status": 0,
  "gesture_uv_token_issued": true,
  "make_cred_ok": true,
  "make_cred_uv_flag_set": true,
  "timely_reset_status": 0,
  "timely_reset_ok": true,
  "post_reset_client_pin_is_false": true,
  "post_reset_retries": 8,
  "old_credential_invalidated_after_reset": true,
  "late_reset_status": 48,
  "late_reset_rejected_with_0x30": true,
  "pin_retained_after_late_reset": true
}
```

