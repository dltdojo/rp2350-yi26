#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp191 — the case that must not be pressed. Needs a board and **nobody**.
#
#   ./nopress.sh
#
# It used to be the fourth case of ./run.sh, which asks a person for four
# presses and signals every one of them by the LED going solid. This case lights
# the same LED and must be answered by nobody — so it was asking, in the only
# channel a person at the board has, for the one press that must never happen.
# The instruction not to press was printed to a terminal nobody is sitting at.
#
# exp189 paid for this lesson first. This is the second time, which is why the
# rule is now written in both experiments and in the repository's own memory:
# **a solid LED means press, always, with no exception to remember.**

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

[[ -f vault.bin && -f cred.id ]] || {
    echo "no vault here — run ./run.sh first, which leaves one" >&2
    exit 1
}

echo ">>> the board will ask for a press. Nobody answers it. That is the measurement." >&2
echo ">>> leave it alone for about a minute." >&2

{
echo "-- nobody pressed --"
timeout 120 ./wrapper.sh whoami > /tmp/exp191-nopress.out 2>&1
echo "wrapper exit: $?"
grep -oE "no key, so no vault.*" /tmp/exp191-nopress.out | head -1
echo "did the CLI run anyway? $(grep -c 'logged in as' /tmp/exp191-nopress.out)"
echo "decrypted directories left behind: $(ls -d "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/exp191.* 2>/dev/null | wc -l)"
rm -f /tmp/exp191-nopress.out
} 2>&1 | tee nopress.txt

echo
echo ">>> wrote nopress.txt" >&2
python3 verify.py capture.txt nopress.txt
