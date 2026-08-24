<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 rp2350-yi26 contributors -->

# exp186 — The Number Behind the Finger

## Question

Can the RP2350 enforce the full CTAP 2.1 PIN lifecycle state machine — initial `clientPin: false`, setting a PIN (`setPIN` 0x03), tracking retry counters with decrement upon failure (`CTAP2_ERR_PIN_INVALID` 0x31) and lockout (`CTAP2_ERR_PIN_BLOCKED` 0x34), issuing an encrypted `pinUvAuthToken` (`getPinToken` 0x05), and setting `FLAG_UV` (`0x04`) in `authData` for PIN-authenticated `makeCredential` and `getAssertion`?

## Background & Lineage

- **[exp174](../exp174-the-authenticator-in-the-middle)** verified CTAP 2.0 WebAuthn registration and assertion.
- **[exp176](../exp176-the-watchful-client)** established keepalive packets during presence waits.
- **[exp177](../exp177-the-interrupted-handshake)** proved CTAPHID channel timeouts and cancellation semantics.
- **[exp184](../exp184-the-client-that-must-know)** exposed `pinUvAuthProtocols: [1]` and handled `getPinRetries` (0x01) for browser pre-flight checks.
- **[exp185](../exp185-a-channel-before-a-secret)** implemented PIN Protocol 1 ECDH P-256 key agreement, AES-256-CBC encrypted tunnel, and HMAC-SHA256 authentication.

`exp186` combines the cryptographic tunnel from exp185 with a stateful PIN management engine.

## Implementation Architecture

```
                       +-----------------------------------+
                       |        Initial Board State        |
                       | clientPin: false, retries: 8      |
                       +-----------------+-----------------+
                                         |
                                  setPIN(0x03)
                           AES-256-CBC(PIN) + HMAC
                                         |
                                         v
                       +-----------------+-----------------+
                       |         PIN Configured            |
                       | clientPin: true, retries: 8       |
                       +--------+------------------+-------+
                                |                  |
                   getPinToken(wrong)     getPinToken(correct)
                                |                  |
                                v                  v
                       +--------+-------+  +-------+-------------------+
                       | retries -= 1   |  | retries = 8               |
                       | err: 0x31/0x34 |  | issue pinUvAuthToken (32B)|
                       +----------------+  +-------+-------------------+
                                                   |
                                     makeCredential / getAssertion
                                     pinUvAuthParam = HMAC(token, cdh)
                                                   |
                                                   v
                                           +-------+-------------------+
                                           | authData flags |= FLAG_UV |
                                           | (bit 2: 0x04)             |
                                           +---------------------------+
```

### 1. State Representation (`PinState`)
- `is_set`: Boolean indicating if a PIN has been established.
- `pin_hash`: 16-byte prefix `SHA-256(pin)[0..16]`.
- `retries_remaining`: 8-attempt counter, decremented on wrong PIN input and reset to 8 upon successful PIN presentation.
- `active_token`: Ephemeral 32-byte `pinUvAuthToken` issued upon successful `getPinToken`.

### 2. PIN Protocol 1 Operations
- **`setPIN` (`0x03`)**: Decrypts 64-byte padded payload, hashes PIN, sets `is_set = true`, and flips `clientPin: true` in `getInfo`.
- **`changePIN` (`0x04`)**: Decrypts and verifies old PIN hash before updating to new PIN.
- **`getPinToken` (`0x05`)**: Verifies PIN hash against stored hash. If incorrect, decrements counter (returning `0x31` or `0x34` if exhausted). If valid, generates random 32-byte token, encrypts via AES-256-CBC with zero-IV under the shared secret, and returns `{ 0x02: tokenEnc }`.

### 3. User Verification (`FLAG_UV`)
When `makeCredential` (key `0x08`) or `getAssertion` (key `0x07`) includes `pinUvAuthParam`, the authenticator computes:
$$\text{HMAC-SHA256}(\text{pinUvAuthToken}, \text{clientDataHash})[0..16] == \text{pinUvAuthParam}$$
Upon match, `authData[32]` flags include `FLAG_UV` (`0x04`).

## Expected Output

Running `./check.sh` on Ubuntu against a connected Pico 2:

```
PASS  exp186-the-number-behind-the-finger has a row in the experiments index
PASS  exp186 has a row in the USB channel table
PASS  python3 present
PASS  firmware compiles (302456 byte ELF)
PASS  PinState struct and retry counter implemented
PASS  setPIN (0x03) subCommand handled
PASS  getPinToken (0x05) subCommand handled
PASS  FLAG_UV (0x04) set in authData when pinUvAuthParam verified
      ruling on pin-lifecycle-probe.json
PASS  initial clientPin is false
PASS  initial retries remaining is 8
PASS  setPIN succeeded (0x00)
PASS  clientPin is true after setPIN
PASS  wrong PIN rejected with CTAP2_ERR_PIN_INVALID (0x31) and decremented retries to 7
PASS  correct PIN issued pinUvAuthToken and reset retries to 8
PASS  makeCredential with pinUvAuthParam succeeded with FLAG_UV (0x04)
PASS  getAssertion with pinUvAuthParam succeeded with FLAG_UV (0x04)
PASS  a board is running exp186
PASS  the README names exp174
PASS  the README names exp176
PASS  the README names exp177
PASS  the README names exp184
PASS  the README names exp185
```

Running `python3 pin_lifecycle_probe.py`:

```json
{
  "device": "/dev/hidraw5",
  "initial_client_pin_is_false": true,
  "initial_retries": 8,
  "set_pin_ok": true,
  "post_client_pin_is_true": true,
  "bad_pin_status": 49,
  "bad_pin_decremented_retries": true,
  "good_pin_status": 0,
  "good_pin_reset_retries": true,
  "token_derived_prefix": "c7e660a29dac7960",
  "make_cred_ok": true,
  "make_cred_uv_flag_set": true,
  "get_assert_ok": true,
  "get_assert_uv_flag_set": true
}
```

