#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp191 — the thing under test.
#
# A CLI's credentials live in a directory. This decrypts that directory into a
# tmpfs with a key **that is not on this machine**, points the CLI at it with an
# environment variable, runs it, and wipes the copy on the way out.
#
#   ./wrapper.sh [--cli PATH] whoami
#
# The key comes from a board that somebody pressed. Without the board the vault
# is ciphertext and the CLI has no credentials at all — which is the claim, and
# which is why the interesting assertion in verify.py is the one taken with the
# board unplugged.
#
# **What this does not claim.** exp163 measured how long a secret sits in the
# open, and it applies here unchanged: while the CLI runs, the token is
# plaintext in a tmpfs and in that process's memory. What is honest to say is
# "it never touches the disk", and the run measures that rather than asserting
# it.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

CLI=./mock-cli.sh
if [[ "${1:-}" == "--cli" ]]; then
    CLI="$2"
    shift 2
fi

VAULT=vault.bin
[[ -f "$VAULT" && -f "$VAULT.salt" && -f cred.id ]] || {
    echo "no vault here — run ./seal.sh first (it needs one press)" >&2
    exit 1
}

SALT="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["salt"])' "$VAULT.salt")"

echo ">>> asking the board. PRESS BOOTSEL when the LED goes solid." >&2
KEY=""
for try in 1 2; do
    KEY="$(python3 getkey.py "$(cat cred.id)" "$SALT" 2>/dev/null)" && [[ -n "$KEY" ]] && break
    [[ "$try" -eq 1 ]] && echo ">>> window closed — press BOOTSEL when the LED goes solid" >&2
done
[[ -n "$KEY" ]] || {
    echo "no key, so no vault. The board is the whole lock." >&2
    exit 1
}

# tmpfs, and nowhere else. /run/user/UID is one on every systemd host; a plain
# mktemp in /tmp is a real filesystem on plenty of them, which would put the
# decrypted token on a disk and quietly break the only claim this makes.
RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
[[ -d "$RUNTIME" ]] || { echo "no tmpfs at $RUNTIME — refusing to decrypt onto a disk" >&2; exit 1; }
WORK="$(mktemp -d "$RUNTIME/exp191.XXXXXX")"

# Wiped on **every** exit, not just the clean one. A Ctrl-C that leaves a
# decrypted credential behind is the failure this whole wrapper is about.
cleanup() {
    rm -rf "$WORK"
    echo ">>> wiped $WORK" >&2
}
trap cleanup EXIT INT TERM

VAULT_KEY="$KEY" python3 vault.py open "$VAULT" "$WORK" > /dev/null || {
    echo "the vault did not open with that key" >&2
    exit 1
}

echo ">>> running: MOCKCLI_CONFIG_DIR=$WORK $CLI $*" >&2
MOCKCLI_CONFIG_DIR="$WORK" "$CLI" "$@"
