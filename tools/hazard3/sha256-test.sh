#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# tools/hazard3 — the harness's SHA-256, compiled for this machine and held
# against Python's hashlib at the lengths around every padding boundary, and
# at 64 KiB, the region exp209 hashes.
#
#   sha256-test.sh      PASS/FAIL; exit 0 = all agree

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
cat > "$work/main.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include "sha256.h"
int main(int argc, char **argv) {
    unsigned n = (unsigned)atoi(argv[1]);
    uint8_t *b = malloc(n + 1), d[32];
    for (unsigned i = 0; i < n; i++) b[i] = (uint8_t)(i * 7 + 3);
    sha256(b, n, d);
    for (int i = 0; i < 32; i++) printf("%02x", d[i]);
    printf("\n");
    return 0;
}
C
cc -O2 -I harness -o "$work/sha" "$work/main.c" harness/sha256.c || { echo "FAIL  the harness's SHA-256 builds for this machine"; exit 1; }
lengths="0 1 55 56 60 63 64 65 119 120 127 128 1000 65536"
bad=0
for n in $lengths; do
    want="$(python3 -c "import hashlib,sys; n=int(sys.argv[1]); print(hashlib.sha256(bytes((i*7+3)&255 for i in range(n))).hexdigest())" "$n")"
    [[ "$("$work/sha" "$n")" == "$want" ]] || { echo "FAIL  SHA-256 of $n bytes"; bad=1; }
done
[[ $bad -eq 0 ]] && echo "PASS  the harness's SHA-256 agrees with hashlib at $(wc -w <<< "$lengths") lengths, 0 to 65536"
exit "$bad"
