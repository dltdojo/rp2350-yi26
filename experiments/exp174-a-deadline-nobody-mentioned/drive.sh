#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Everything exp174 measures that a person is not needed for.
#
#   ./drive.sh
#
# The experiment's subject is a browser, and a browser cannot be scripted: its
# key dialog is native UI. But the *device* half of every finding here can be
# watched without one, because a `button` build that has just been asked for a
# credential is sitting in its presence wait — the exact state this experiment
# is about. So a client can count what it sends while nobody presses anything,
# and then withdraw the request and read what comes back.
#
# Three firmwares, no finger:
#
#   button + keepalive=on   -> packets arrive while it waits, and CANCEL is answered
#   button + keepalive=off  -> exp173's silence, same wait, nothing sent
#   none                    -> the TRNG, timed, which is what a browser found
#
# The browser half is ab.sh, and it needs somebody at a keyboard.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
LOGFILE="$(mktemp)"
trap 'rm -f "$LOGFILE"' EXIT

say() { printf '>>> host: %s\n' "$*"; }
show() { sed 's/^/    /'; }

build() {  # build <up> <keepalive> <outfile>
    EXP174_UP="$1" EXP174_KEEPALIVE="$2" cargo build --release > /dev/null 2>&1 || {
        echo "build failed for UP=$1 KEEPALIVE=$2"; exit 1; }
    elf2flash convert -b rp2350 \
        target/thumbv8m.main-none-eabihf/release/exp174-a-deadline-nobody-mentioned \
        "target/$3" > /dev/null 2>&1
}

flash() {
    yi26 bootsel > /dev/null 2>&1
    sleep 2
    yi26 pflash "target/$1" > /dev/null 2>&1
    # exp173's six seconds. This image is larger again, and a settle time that
    # was long enough before is a race afterwards.
    sleep 7
}

say "building the three firmwares"
build button on  exp174-drive-keepalive.uf2
build button off exp174-drive-silent.uf2
build none   on  exp174-drive-none.uf2

for ARM in keepalive silent; do
    say "flashing button + $ARM"
    flash "exp174-drive-$ARM.uf2"
    yi26 log --seconds 40 > "$LOGFILE" 2>&1 &
    LOGPID=$!
    sleep 1

    # Watch the wait. The board is asked for a credential and nobody presses
    # anything; what it sends in that window is the whole of one arm.
    say "case keepalive ($ARM): counting what arrives while it waits"
    python3 ctaphid.py keepalive 2.0 2>&1 | show

    # The presence wait is ten seconds and the board is still in it.
    sleep 12

    say "case cancel ($ARM): withdraw the request mid-wait"
    python3 ctaphid.py cancel 1.0 2>&1 | show

    sleep 2
    kill "$LOGPID" 2>/dev/null
    wait "$LOGPID" 2>/dev/null
    say "the board's own account, $ARM"
    grep -vE 'idle:|^\[ +[0-9]+ ms\] {2}(FIDO|06d0|4081|init pack|max mess|a transa|device se|versions|getInfo body)' \
        "$LOGFILE" | show
done

say "flashing the unattended build, to time the TRNG"
flash exp174-drive-none.uf2
yi26 log --seconds 40 > "$LOGFILE" 2>&1 &
LOGPID=$!
sleep 1
DEV="$(fido2-token -L 2>/dev/null | head -1 | cut -d: -f1)"
for i in 1 2 3 4 5; do
    printf '%s\n%s\n%s\n%s\n' \
        "$(head -c 32 /dev/urandom | base64)" "example.test" "somebody" \
        "$(head -c 16 /dev/urandom | base64)" > "$LOGFILE.in"
    fido2-cred -M "$DEV" < "$LOGFILE.in" > /dev/null 2>&1 || true
done
rm -f "$LOGFILE.in"
sleep 2
kill "$LOGPID" 2>/dev/null
wait "$LOGPID" 2>/dev/null
say "32 bytes of TRNG, five times"
grep 'TRNG took' "$LOGFILE" | show
