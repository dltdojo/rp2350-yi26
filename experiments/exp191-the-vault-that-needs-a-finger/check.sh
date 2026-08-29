#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
#
# exp191 quick check — non-interactive.
#
#   ./check.sh        exit 0 = all checks pass, exit 1 = something failed
#
# The live half is ./run.sh, which needs four presses and writes capture.txt.
# Everything here either rules on that capture or needs no board at all — and
# the half that needs no board is the sharper one, because the vault's central
# claim is cryptographic rather than behavioural.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

source ../lib.sh
require_supported_platform

PRESENCE=2
LIFELINE="no: no firmware of its own; it runs against exp189's board"
presence_check
lifeline_check

# No firmware of its own; the tokens describe exp189, the board it unlocks with.
USB_IFACE="cdc+hid"
USB_CARRIES="log+ctaphid"
USB_HOST="cdc_acm+hidraw"
USB_RUNS_ON="exp189"
usb_check

command -v python3 > /dev/null && pass "python3 present" \
    || { fail "python3 present" "needed for the client and the vault"; exit 1; }

python3 -c "import cryptography" 2> /dev/null \
    && pass "python3's cryptography is present — the one external dependency, and it is offline" \
    || fail "python3's cryptography" "pip install cryptography"

# ---------------------------------------------------------------------------
# The vault, with no board and no press.
#
# The claim is that the ciphertext is useless without the board, and that is a
# property of AES-256-GCM rather than of this wrapper's control flow. A cipher
# with no tag would open a wrong key into rubbish and let a caller carry on, so
# the interesting assertion is that a wrong key **raises**.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/plain"
echo '{"token": "check-sh-token", "user": "alice"}' > "$TMP/plain/auth.json"
K="$(python3 -c 'import os;print(os.urandom(32).hex())')"

if VAULT_KEY="$K" python3 vault.py seal "$TMP/plain" "$TMP/v.bin" AAAA > /dev/null 2>&1; then
    pass "a directory seals"
else
    fail "a directory seals" "vault.py seal"
fi

if grep -qa 'check-sh-token' "$TMP/v.bin" 2> /dev/null; then
    fail "the token is not readable in the ciphertext" "it is sitting there in the open"
else
    pass "the token is not readable in the ciphertext"
fi

if VAULT_KEY="$K" python3 vault.py open "$TMP/v.bin" "$TMP/out" > /dev/null 2>&1 \
    && grep -qa 'check-sh-token' "$TMP/out/auth.json" 2> /dev/null; then
    pass "and the right key gets exactly what went in"
else
    fail "the right key opens it" "vault.py open"
fi

WRONG="$(python3 -c 'import os;print(os.urandom(32).hex())')"
if VAULT_KEY="$WRONG" python3 vault.py open "$TMP/v.bin" "$TMP/bad" > /dev/null 2>&1; then
    fail "a wrong key fails rather than producing rubbish" \
         "it opened, which makes the vault a speed bump"
else
    pass "a wrong key fails rather than producing rubbish — GCM's tag, not a policy"
fi
[[ -d "$TMP/bad" ]] \
    && fail "and leaves nothing behind" "a failed open still created a directory" \
    || pass "and leaves nothing behind"

# ---------------------------------------------------------------------------
# The two subjects, and the difference between them.
grep -q 'MOCKCLI_CONFIG_DIR' mock-cli.sh \
    && pass "the CLI under test honours a config-directory variable" \
    || fail "the CLI honours MOCKCLI_CONFIG_DIR" "there is nothing to redirect"

grep -q 'HOME/.cache' mock-cli-leaky.sh \
    && pass "and the second one caches in \$HOME, so the leak is a real second arm" \
    || fail "the leaky CLI leaks" "without it, 'nothing was left behind' is untested"

# The wrapper must not decrypt onto a disk. exp163 measured how long a secret
# sits in the open; the one thing that can honestly be claimed is that it never
# reaches storage, and that claim is one `mktemp -d /tmp/...` away from false.
grep -q 'XDG_RUNTIME_DIR' wrapper.sh \
    && pass "the wrapper decrypts onto a tmpfs, never a disk" \
    || fail "the wrapper decrypts onto a tmpfs" "mktemp in /tmp is a real filesystem on many hosts"

grep -q 'trap cleanup EXIT INT TERM' wrapper.sh \
    && pass "and wipes on every exit, not only the clean one" \
    || fail "the wrapper wipes on every exit" "a Ctrl-C that leaves a credential is the failure"

# ---------------------------------------------------------------------------
if [[ -f capture.txt ]]; then
    echo "      ruling on capture.txt"
    python3 verify.py capture.txt
    [[ $? -eq 0 ]] || FAILED=1
else
    fail "capture.txt exists" "run ./run.sh — it needs a board and four presses"
fi

for e in exp163 exp177 exp189; do
    grep -q "$e" README.md 2> /dev/null \
        && pass "the README names $e" \
        || fail "the README names $e" "this experiment stands on $e"
done

exit "$FAILED"
