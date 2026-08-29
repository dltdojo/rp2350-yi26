#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp191 — the whole run, in one sitting.
#
#   ./run.sh          needs a board and **four presses**
#
# Four solid-LED windows, and every one of them means press. There is no case
# here that must not be pressed: exp189 learned that a solid LED may only ever
# mean one thing, and the case that must not be answered lives in its own
# script. A missed press costs one extra window, not the run.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

say() { printf '>>> %s\n' "$*"; }

{
echo "=== exp191 — the vault that needs a finger ==="
echo

say "four solid-LED windows follow. Press BOOTSEL at every one of them."
say "there is no case here that must not be pressed — that one is ./nopress.sh"
echo

# ---------------------------------------------------------------- seal it
say "1-2/4: making a credential and sealing the CLI's config"
./seal.sh || { echo "seal failed"; exit 1; }
echo "-- sealed --"
ls -l vault.bin | awk '{print "vault.bin", $5, "bytes"}'
echo "salt, in the clear: $(python3 -c 'import json;print(json.load(open("vault.bin.salt"))["salt"])')"
echo "a token anywhere in the vault? $(grep -c 'sealed-' vault.bin 2>/dev/null || echo 0)"
echo

# ------------------------------------- what it is without the board, free
say "no board, no key: the cryptography, not a policy"
echo "-- no key --"
VAULT_KEY="$(python3 -c 'import os;print(os.urandom(32).hex())')" \
    python3 vault.py open vault.bin /tmp/exp191-should-not-exist 2>&1 | tail -1
echo "did a wrong key produce a directory? $([[ -d /tmp/exp191-should-not-exist ]] && echo yes || echo no)"
rm -rf /tmp/exp191-should-not-exist
echo

# The case that must not be pressed is **not here**, and this is the second
# time this repository has had to learn it. exp189 moved its own out after a key
# came out twice; this script kept one anyway, printed "DO NOT PRESS for this
# one" to a terminal nobody is sitting at, and a person pressing at every solid
# LED — which is what they were told, correctly — answered it.
#
# A solid LED means press. Always. ./nopress.sh is the other half, it needs
# nobody, and it is meant to be started and walked away from.

# ------------------------------------------------------------- open it
say "3/4: opening it, with the honest CLI"
echo "-- honest --"
./wrapper.sh whoami 2>&1 | grep -E "mock-cli|running:|wiped" | head -4
echo

# ------------------------------------------- and what the CLI left behind
say "4/4: the same, with a CLI that quietly caches in \$HOME"
echo "-- leaky --"
rm -rf "$HOME/.cache/mock-cli"
./wrapper.sh --cli ./mock-cli-leaky.sh login leaked-on-purpose 2>&1 | grep -E "mock-cli|wiped" | head -3
echo "left in \$HOME/.cache: $([[ -f "$HOME/.cache/mock-cli/last-session.json" ]] && echo yes || echo no)"
echo "and the token is readable there: $(grep -c 'leaked-on-purpose' "$HOME/.cache/mock-cli/last-session.json" 2>/dev/null || echo 0)"
rm -rf "$HOME/.cache/mock-cli"
echo

say "what the tmpfs holds now"
echo "-- residue --"
echo "exp191 directories left in the runtime dir: $(ls -d "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/exp191.* 2>/dev/null | wc -l)"
echo "token findable anywhere under it: $(grep -rl 'sealed-' "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" 2>/dev/null | wc -l)"
} 2>&1 | tee capture.txt

echo
say "wrote capture.txt"
python3 verify.py capture.txt nopress.txt 2>/dev/null || python3 verify.py capture.txt
say "now run ./nopress.sh — it needs nobody, and nothing it does should be pressed"
