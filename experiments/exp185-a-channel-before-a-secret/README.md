# exp185 — a channel before a secret

[exp184](../exp184-the-client-that-must-know/) answered strict client status
queries (`getInfo` and `getPinRetries`). But when a client wants to set a PIN,
change a PIN, or retrieve a PIN-authenticated token, raw PIN bytes can never
travel across USB in plaintext.

Before exchanging secrets, the client and the authenticator must establish an
encrypted, authenticated channel. This is **PIN Protocol 1** (CTAP 2.1 Section 6.5.5).

The fourteenth on the [authenticator road](../README.md#the-authenticator-road).

> **Verified on hardware, 2026-08-24.** The board executes ECDH P-256 key
> agreement on demand, decapsulates shared secrets, decrypts 64-byte PIN payloads
> with AES-256-CBC (zero-IV), and authenticates transactions via truncated
> 16-byte HMAC-SHA256 (`pinAuth`). Corrupted signatures are rejected with
> `CTAP2_ERR_PIN_AUTH_INVALID` (`0x32`).

---

## The Protocol Mechanics

### 1. Key Agreement (`getKeyAgreement`, subCommand `0x02`)
The host requests the authenticator's ephemeral P-256 public key:
```text
Client  -> { 0x02: 0x02 }
Board   <- { 0x01: { 1: 2, -1: 1, -2: x_B, -3: y_B } }
```

### 2. Shared Secret Derivation (ECDH)
The client generates ephemeral keypair $(a, a \cdot G)$ and calculates:
$$Z = a \cdot (b \cdot G) = (x_Z, y_Z)$$
$$\text{sharedSecret} = \text{SHA-256}(x_Z)$$

### 3. AES-256-CBC Encrypted Tunnel & HMAC-SHA256 `pinAuth`
When sending a PIN or sensitive token:
* **Ciphertext**: $\text{AES-256-CBC}(\text{key}=\text{sharedSecret}, \text{IV}=0, \text{padded\_pin})$
* **Authentication**: $\text{pinAuth} = \text{HMAC-SHA256}(\text{sharedSecret}, \text{ciphertext})[0..16]$

```text
Client  -> { 1: 1, 2: 3, 3: COSE_Key(A), 4: pinAuth, 5: newPinEnc }
Board   -> decapsulates sharedSecret
           verifies pinAuth
           decrypts newPinEnc
        <- CTAP2_OK (0x00) {}
```

---

## Running it

```console
cargo build --release
elf2flash convert -b rp2350 target/thumbv8m.main-none-eabihf/release/exp185-a-channel-before-a-secret target/exp185.uf2
yi26 flash target/exp185.uf2
```

Run the automated test probe:

```console
python3 pin_channel_probe.py
./check.sh
```

---

## Expected output

```text
PASS  python3 present
PASS  firmware compiles (299108 byte ELF)
PASS  authenticatorClientPIN (0x06) command handled in dispatch
PASS  ECDH P-256 key agreement and decapsulation implemented
PASS  AES-256-CBC decryption implemented
PASS  HMAC-SHA256 pinAuth verification implemented
      ruling on pin-channel-probe.json
PASS  getInfo declares FIDO_2_1 version
PASS  pinUvAuthProtocols declares [1]
PASS  getKeyAgreement returned CTAP2_OK (0x00) with ephemeral P-256 COSE_Key
PASS  PIN Protocol 1 tunnel verified (ECDH + HMAC pinAuth + AES-256-CBC)
PASS  tampered pinAuth correctly rejected with CTAP2_ERR_PIN_AUTH_INVALID (0x32)
PASS  a board is running exp185
PASS  the README names exp174
PASS  the README names exp176
PASS  the README names exp177
PASS  the README names exp184
```

---

## What this is not

* **Not Flash PIN storage.** Decrypted PINs are validated and dropped; persistent
  storage and retry counter management belong to [exp186](../exp186-the-number-behind-the-finger/).
* **Not PIN Protocol 2.** Protocol 2 adds HKDF-based key separation (`CTAP2 AES key` and `CTAP2 HMAC key`).

