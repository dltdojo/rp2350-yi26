<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 rp2350-yi26 contributors -->

# exp188 — The Passkey in the Pocket

## Question

Can the RP2350 support full modern Passkeys — storing CTAP 2.1 Discoverable Credentials (`options: { "rk": true }`), performing username-less 1-Click login during `getAssertion` with empty `allowList` (locating resident passkeys and returning user entities), and implementing `authenticatorCredentialManagement` (`credMgmt` 0x0A) for credential inspection and purging?

## Background & Lineage

- **[exp174](../exp174-the-authenticator-in-the-middle)** verified CTAP 2.0 WebAuthn registration and assertion.
- **[exp176](../exp176-the-watchful-client)** established CTAPHID keepalive packets during presence waits.
- **[exp177](../exp177-the-interrupted-handshake)** proved CTAPHID channel timeouts and cancellation semantics.
- **[exp184](../exp184-the-client-that-must-know)** exposed `pinUvAuthProtocols: [1]` and handled `getPinRetries` (0x01).
- **[exp185](../exp185-a-channel-before-a-secret)** implemented PIN Protocol 1 ECDH P-256 key agreement and AES-256-CBC encrypted tunnel.
- **[exp186](../exp186-the-number-behind-the-finger)** implemented the stateful CTAP 2.1 PIN lifecycle and `pinUvAuthToken` issuance with `FLAG_UV` (`0x04`).
- **[exp187](../exp187-the-three-taps-and-the-reset)** established the 10-second factory reset power-on interlock (`authenticatorReset` 0x07) and triple-tap gesture UV.

`exp188` brings full modern Passkey capability to the RP2350: on-device resident credential storage and CTAP 2.1 credential management.

## Implementation Architecture

```
                 +-----------------------------------------------+
                 |  authenticatorMakeCredential(rk: true)        |
                 |  -> Generates credential                      |
                 |  -> Saves UserEntity + rpID in ResidentStore  |
                 +-----------------------+-----------------------+
                                         |
                       +-----------------+-----------------+
                       |                                   |
                       v                                   v
   +---------------------------------------+   +---------------------------------------+
   | authenticatorGetAssertion(allow: [])  |   | authenticatorCredentialManagement     |
   | -> Empty allowList 1-Click login      |   | (0x0A)                                |
   | -> Locates Passkey by rpIDHash        |   | -> 0x01: getCredsMetadata             |
   | -> Returns assertion + UserEntity     |   | -> 0x02: enumerateRPsBegin            |
   |    (id, name, displayName)            |   | -> 0x04: enumerateCredentialsBegin    |
   +---------------------------------------+   | -> 0x06: deleteCredential             |
                                               +---------------------------------------+
```

### 1. Resident Passkey Storage (`ResidentStore`)
- Stores up to 16 discoverable credentials directly in authenticator memory.
- Preserves `rp_id`, `user_id`, `user_name`, `user_display_name`, and `cred_id`.
- Automatically wiped upon factory reset (`authenticatorReset` `0x07`).

### 2. Username-less 1-Click Passkey Login
When a browser initiates 1-click Passkey authentication (sending `authenticatorGetAssertion` with an empty `allowList` `allow: []`):
- The authenticator locates the matching resident key by `rpIdHash`.
- Signs the assertion with the user's private key.
- Returns the full UserEntity (`user: { "id": user_id, "name": user_name, "displayName": user_display_name }`) alongside `credential` and signature.

### 3. Credential Management (`credMgmt` `0x0A`)
Protected by `pinUvAuthToken`:
- **`getCredsMetadata` (`0x01`)**: Reports existing resident count and remaining storage capacity.
- **`enumerateRPsBegin` (`0x02`)**: Lists Relying Parties with stored credentials.
- **`enumerateCredentialsBegin` (`0x04`)**: Lists credentials under an RP.
- **`deleteCredential` (`0x06`)**: Purges a credential by `credentialId`.

## Expected Output

Running `./check.sh` on Ubuntu against a connected Pico 2:

```
PASS  python3 present
PASS  firmware compiles (302456 byte ELF)
PASS  ResidentStore struct and resident key storage implemented
PASS  authenticatorCredentialManagement (0x0A) handled in dispatch
PASS  Passkey rk: true option supported
      ruling on passkey-credmgmt-probe.json
PASS  getInfo advertises options: { rk: true, credMgmt: true }
PASS  PIN configured and pinUvAuthToken derived successfully
PASS  credMgmt getCredsMetadata (0x01) reports initial existing=0, remaining=16
PASS  makeCredential with options: { rk: true } registered resident passkey
PASS  credMgmt getCredsMetadata reports post-registration existing=1, remaining=15
PASS  1-Click Passkey assertion (empty allowList) located resident key and returned user entity
PASS  credMgmt enumerateRPsBegin (0x02) and enumerateCredentialsBegin (0x04) succeeded
PASS  credMgmt deleteCredential (0x06) purged passkey; metadata=0, empty assertion rejected
PASS  a board is running exp188
PASS  the README names exp174
PASS  the README names exp176
PASS  the README names exp177
PASS  the README names exp184
PASS  the README names exp185
PASS  the README names exp186
PASS  the README names exp187
```

Running `python3 passkey_credmgmt_probe.py`:

```json
{
  "device": "/dev/hidraw5",
  "rk_option_is_true": true,
  "cred_mgmt_option_is_true": true,
  "uv_option_is_true": true,
  "set_pin_ok": true,
  "pin_uv_auth_token_derived": true,
  "initial_metadata_existing_count": 0,
  "initial_metadata_remaining_count": 16,
  "passkey_registration_ok": true,
  "post_registration_existing_count": 1,
  "post_registration_remaining_count": 15,
  "one_click_passkey_assertion_ok": true,
  "one_click_returned_user_alice": true,
  "one_click_returned_matching_cred_id": true,
  "enumerate_rps_ok": true,
  "enumerate_credentials_ok": true,
  "delete_credential_ok": true,
  "post_deletion_existing_count": 0,
  "post_deletion_assertion_rejected_no_creds": true
}
```

