#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
"""exp191 verification — rules on a capture.txt written by run.sh.

The claim is that a CLI's credentials are unusable without a board somebody
pressed. Two of the rules below are the ones that make it worth anything:

  * a wrong key must **fail**, not produce plausible rubbish — otherwise the
    vault is a speed bump;
  * the leaky CLI must be **caught**, because "the redirection worked" and
    "nothing was left behind" are two claims and a wrapper tested only against
    an honest subject would ship.
"""

import re
import sys


def section(text, name):
    m = re.search(rf"^-- {name} --$(.*?)(?=^-- |\Z)", text, re.S | re.M)
    return m.group(1) if m else ""


def verify(text):
    ok = True

    def rule(good, yes, no):
        nonlocal ok
        print(("PASS  " + yes) if good else ("FAIL  " + no))
        if not good:
            ok = False

    sealed = section(text, "sealed")
    rule("vault.bin" in sealed and "bytes" in sealed,
         "the config directory sealed into a vault",
         "nothing was sealed, so nothing below is a measurement")
    rule("a token anywhere in the vault? 0" in sealed,
         "and the token is not findable in the ciphertext",
         "the token is readable in the vault — it is not encrypted")
    rule("salt, in the clear:" in sealed,
         "the salt sits beside it in the clear, which is what a salt is",
         "no salt was recorded, and without it nothing can ask the board")

    nokey = section(text, "no key")
    rule("did a wrong key produce a directory? no" in nokey,
         "**a wrong key fails rather than producing rubbish** — AES-GCM's tag, not a policy",
         "a wrong key produced a directory: the vault opens into garbage and a caller carries on")

    nopress = section(text, "nobody pressed")
    m = re.search(r"wrapper exit: (\d+)", nopress)
    rule(m and m.group(1) != "0",
         "with the board present and nobody pressing, the wrapper refused",
         "the wrapper ran the CLI without anybody pressing — the finger is not in the loop")
    rule("no key, so no vault" in nopress,
         "and it said why, in one line, rather than failing somewhere further down",
         "it failed without naming the cause")

    honest = section(text, "honest")
    rule("logged in as alice" in honest,
         "pressed, the CLI knows itself — the credentials really were the ones sealed",
         "the CLI did not come up logged in, so the vault did not reach it")
    rule("wiped" in honest,
         "and the decrypted copy was wiped on the way out",
         "nothing reported wiping the decrypted copy")

    leaky = section(text, "leaky")
    rule("left in $HOME/.cache: yes" in leaky,
         "the leaky CLI really did leak, so this arm tests something",
         "the leaky CLI left nothing — it is not a second arm, it is a copy of the first")
    rule(re.search(r"and the token is readable there: [1-9]", leaky) is not None,
         "**and the token is readable in what it left** — the redirection worked perfectly "
         "and the secret still escaped",
         "the leak was recorded but the token was not in it, so this proves nothing")

    residue = section(text, "residue")
    rule("exp191 directories left in the runtime dir: 0" in residue,
         "no decrypted directory survives the run",
         "a decrypted config directory is still on the tmpfs")
    rule("token findable anywhere under it: 0" in residue,
         "and the token is nowhere under the runtime directory",
         "the token is still readable on the tmpfs after the run")

    return ok


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: verify.py capture.txt", file=sys.stderr)
        sys.exit(2)
    with open(sys.argv[1]) as f:
        sys.exit(0 if verify(f.read()) else 1)
