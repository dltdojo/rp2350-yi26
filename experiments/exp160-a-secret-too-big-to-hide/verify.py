#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Check exp160's log, off the board, with something that is not this firmware.

Reads a pasted log on stdin and prints one word on the last line:

    OK          the signature verifies, and the check was shown able to fail
    BAD         the verifier rejected a signature the board says is good
    CANNOTFAIL  a one-bit-corrupted message ALSO verified — the check is useless
    KATBAD      the board's ML-DSA-65 key generation disagrees with OpenSSL
    MISSING     the log does not carry a complete public key, challenge, signature
    OLDPYCA     python-cryptography is present but too old to know about ML-DSA

Two independent checks, on purpose, because they fail in different ways.

1. **The known-answer test needs no library at all.** FIPS-204 key generation is
   deterministic, so the public key for the all-zero seed has exactly one correct
   value. KAT_PK_HEAD below is the first 32 bytes of it, and it was agreed on by
   OpenSSL and by RustCrypto's `ml-dsa` before this file was written. If the
   board prints something else, its cryptography is wrong and nothing else here
   matters. This check runs even on a machine with no `cryptography` installed.

2. **The signature is verified by a different implementation.** A signature
   checked by its own signer proves the two agree; a shared bug in encoding,
   endianness or hashing cancels out perfectly. So this uses `cryptography`,
   which is OpenSSL underneath — a different implementation, in a different
   language, on a different machine.

   And it then flips one bit of the challenge and REQUIRES the verification to
   fail. Without that, a verifier that returned "valid" unconditionally would
   pass every run forever. exp140 is what this repository calls a check that
   cannot fail.

Usage:

    yi26 log --seconds 25 | python3 ./verify.py
    python3 ./verify.py < a-log-somebody-pasted.txt
"""

import re
import sys

PK_LEN = 1952
SIG_LEN = 3309
MSG_LEN = 32

# ML-DSA-65 KeyGen(seed = 32 zero bytes), first 32 bytes of the 1952-byte
# public key. Produced independently by OpenSSL (python-cryptography 50) and by
# RustCrypto ml-dsa 0.1.1, which agreed exactly, on 2026-08-21.
KAT_PK_HEAD = "424b2f267e58d5b3b44d71acfc6a656bb26950d57c61db1c880bcfa1feab443f"

# The board emits the public key and the signature 32 bytes to a line, each line
# carrying its own index, because usb-log truncates at 96 bytes and drops the
# newest line when its 16-deep queue fills. 166 lines in a tight loop would
# arrive as about 16.
CHUNK = re.compile(r"\b(PK|SG)(\d{3})\s+([0-9a-f]+)\s*$")
FLAT = re.compile(r"\b(MSG|KATP)\s+([0-9a-f]{64})\s*$")


def out(word):
    print(word)
    return 0 if word == "OK" else 1


def reassemble(lines):
    """Latest complete copy of each indexed chunk, concatenated in order.

    The board repeats the whole block every few seconds, so a capture usually
    holds several. Taking the last value seen for each index means a capture
    that starts mid-block still reassembles, as long as it ran long enough to
    see every index once.
    """
    parts = {"PK": {}, "SG": {}}
    flat = {}
    for line in lines:
        m = CHUNK.search(line)
        if m:
            parts[m.group(1)][int(m.group(2))] = m.group(3)
            continue
        m = FLAT.search(line)
        if m:
            flat[m.group(1)] = m.group(2)

    def join(tag, want_len):
        d = parts[tag]
        if not d:
            return None
        n = max(d) + 1
        if any(i not in d for i in range(n)):
            return None
        b = bytes.fromhex("".join(d[i] for i in range(n)))
        return b if len(b) == want_len else None

    return join("PK", PK_LEN), join("SG", SIG_LEN), flat


def main():
    lines = sys.stdin.read().splitlines()
    pk, sig, flat = reassemble(lines)

    # 1. The known-answer test. No library needed, so it goes first.
    katp = flat.get("KATP")
    if katp is None:
        return out("MISSING")
    if katp != KAT_PK_HEAD:
        print(f"board KATP {katp}")
        print(f"expected   {KAT_PK_HEAD}")
        return out("KATBAD")

    msg = flat.get("MSG")
    if pk is None or sig is None or msg is None:
        got_pk = 0 if pk is None else len(pk)
        got_sig = 0 if sig is None else len(sig)
        print(f"public key {got_pk}/{PK_LEN} bytes, signature {got_sig}/{SIG_LEN}, "
              f"challenge {'yes' if msg else 'no'}")
        return out("MISSING")
    msg = bytes.fromhex(msg)

    # 2. The other implementation.
    try:
        from cryptography.hazmat.primitives.asymmetric import mldsa
    except ImportError:
        try:
            import cryptography

            print(f"cryptography {cryptography.__version__} has no ML-DSA; "
                  f"needs >= 46. Try: pip install --user 'cryptography>=46'")
            return out("OLDPYCA")
        except ImportError:
            print("python 'cryptography' is not installed; needs >= 46. "
                  "Try: pip install --user 'cryptography>=46'")
            return out("OLDPYCA")

    key = mldsa.MLDSA65PublicKey.from_public_bytes(pk)

    try:
        key.verify(sig, msg)
    except Exception:
        return out("BAD")

    # And prove the check can fail before reporting that it passed.
    corrupt = bytearray(msg)
    corrupt[0] ^= 1
    try:
        key.verify(sig, bytes(corrupt))
        return out("CANNOTFAIL")
    except Exception:
        pass

    print(f"public key {len(pk)} bytes, signature {len(sig)} bytes, "
          f"challenge {len(msg)} bytes")
    return out("OK")


if __name__ == "__main__":
    sys.exit(main())
