#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp228 — the shell's signature check (shell/bip340.c), on this machine.

  bip340.py CC WORK     PASS/FAIL; exit 0 = both pass

Built with CC, it is held to BIP340's own test vectors (bip340/test-vectors.csv)
and to 200 more in the same format: keys and messages drawn from a fixed seed,
each signed by BIP340's reference.py, half left as signed and half with one
bit of the signature, the key or the message flipped — every one of those
half reference.py itself rejects, and bip340.c must too.
"""
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "bip340"))
import reference as bip340  # noqa: E402


def drawn(path, n=200, seed=228):
    rng = random.Random(seed)
    with open(path, "w") as f:
        f.write("index,secret key,public key,aux_rand,message,signature,verification result,comment\n")
        for i in range(n):
            sk = rng.randrange(1, bip340.n).to_bytes(32, "big")
            pk = bip340.pubkey_gen(sk)
            msg = rng.randbytes(rng.choice([0, 1, 32, 32, 100]))
            sig = bip340.schnorr_sign(msg, sk, rng.randbytes(32))
            if i % 2:
                which = rng.choice(["sig", "pk", "msg"] if msg else ["sig", "pk"])
                b = bytearray({"sig": sig, "pk": pk, "msg": msg}[which])
                k = rng.randrange(8 * len(b))
                b[k // 8] ^= 1 << (k % 8)
                sig, pk, msg = (bytes(b) if which == "sig" else sig, bytes(b) if which == "pk" else pk,
                                bytes(b) if which == "msg" else msg)
            ok = bip340.schnorr_verify(msg, pk, sig) if len(pk) == 32 else False
            if i % 2 and ok:
                sys.exit("bip340.py: a flipped bit that reference.py still accepts")
            f.write(f"{i},,{pk.hex()},,{msg.hex()},{sig.hex()},{'TRUE' if ok else 'FALSE'},\n")


def main(cc, work):
    exe = os.path.join(work, "bip340_test")
    shell = os.path.join(HERE, "..", "shell")
    harness = os.path.join(HERE, "..", "..", "..", "tools", "hazard3", "harness")
    subprocess.run([cc, "-O2", "-Wall", "-Werror", "-I", shell, "-I", harness, "-o", exe,
                    os.path.join(shell, "bip340_test.c"), os.path.join(shell, "bip340.c"),
                    os.path.join(harness, "sha256.c")], check=True)
    more = os.path.join(work, "drawn.csv")
    drawn(more)
    failed = 0
    for csv, label in ((os.path.join(HERE, "..", "bip340", "test-vectors.csv"), "of BIP340's test vectors"),
                       (more, "signatures reference.py made, half of them with a bit flipped,")):
        r = subprocess.run([exe, csv, label], capture_output=True, text=True)
        print(r.stdout.strip())
        failed |= r.returncode != 0
    return failed


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sys.exit(1 if main(sys.argv[1], sys.argv[2]) else 0)
