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
ERRLOG="$(mktemp)"

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
# Retried only on a **timed-out** window, never on a crash.
#
# The first version retried on any failure, and getkey.py was shipped with an
# import left behind: it died in 0.3 s, three times, while this loop said
# "window closed — press BOOTSEL" and somebody stood there pressing a button at
# a script that was never going to ask. A retry that cannot tell a missed press
# from a broken client spends a person's time on the wrong thing.
KEY=""
for try in 1 2; do
    START=$(date +%s)
    if KEY="$(python3 getkey.py "$(cat cred.id)" "$SALT" 2> "$ERRLOG")" && [[ -n "$KEY" ]]; then
        break
    fi
    if [[ $(( $(date +%s) - START )) -lt 5 ]]; then
        echo "getkey.py failed in under five seconds — that is not a missed press:" >&2
        tail -3 "$ERRLOG" >&2
        exit 1
    fi
    echo ">>> window $try closed — press BOOTSEL when the LED goes solid" >&2
done
[[ -n "$KEY" ]] || { echo "no key, so no vault. The board is the whole lock." >&2; exit 1; }

# tmpfs, and nowhere else. /run/user/UID is one on every systemd host; a plain
# mktemp in /tmp is a real filesystem on plenty of them, which would put the
# decrypted token on a disk and quietly break the only claim this makes.
RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
[[ -d "$RUNTIME" ]] || { echo "no tmpfs at $RUNTIME — refusing to decrypt onto a disk" >&2; exit 1; }
WORK="$(mktemp -d "$RUNTIME/exp191.XXXXXX")"

# Wiped on **every** exit, not just the clean one. A Ctrl-C that leaves a
# decrypted credential behind is the failure this whole wrapper is about.
cleanup() {
    rm -rf "$WORK" "$ERRLOG"
    echo ">>> wiped $WORK" >&2
}
trap cleanup EXIT INT TERM

VAULT_KEY="$KEY" python3 vault.py open "$VAULT" "$WORK" > /dev/null || {
    echo "the vault did not open with that key" >&2
    exit 1
}

echo ">>> running: MOCKCLI_CONFIG_DIR=$WORK $CLI $*" >&2
MOCKCLI_CONFIG_DIR="$WORK" "$CLI" "$@"
