#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# tools/lean setup — fetch the Lean 4 proof checker, once.
#
# Pinned by release AND by sha256, the way tools/tlc pins TLC. It is fetched,
# never committed (this directory's .gitignore), and it is not small: the
# release is a 580 MB .tar.zst that unpacks to 2.9 GB, against TLC's 2 MB jar.
# Most of that is Lean's own library and compiler; exp198 uses none of it but
# the core, and there is no smaller official download.
#
# Unpacking a .tar.zst needs `zstd`, or python3 with the `zstandard` module
# (`pip install zstandard`) when there is no `zstd` binary.
#
#   ./setup.sh          fetch, verify and unpack, or say what is already there

set -eu
cd "$(dirname "${BASH_SOURCE[0]}")"

LEAN_VERSION="4.34.0"
LEAN_SHA256="caaa98356098c85dc0fcbbd28e1ec66f39eb6551829972b752ff20e1286b646b"
DIR="lean-$LEAN_VERSION-linux"
TARBALL="$DIR.tar.zst"
STAMP="$DIR/.sha256"

if [[ -x "$DIR/bin/lean" && "$(cat "$STAMP" 2>/dev/null)" == "$LEAN_SHA256" ]]; then
    echo "already have Lean $LEAN_VERSION ($LEAN_SHA256)"
    exit 0
fi

verify() { [[ "$(sha256sum "$TARBALL" | cut -d' ' -f1)" == "$LEAN_SHA256" ]]; }

if ! { [[ -f "$TARBALL" ]] && verify; }; then
    curl -sSfL --max-time 1800 -o "$TARBALL.part" \
        "https://github.com/leanprover/lean4/releases/download/v$LEAN_VERSION/$TARBALL"
    mv "$TARBALL.part" "$TARBALL"
    if ! verify; then
        echo "$TARBALL does not match the pinned sha256 — refusing to use it" >&2
        rm -f "$TARBALL"
        exit 1
    fi
fi

rm -rf "$DIR"
if command -v zstd > /dev/null; then
    zstd -dc "$TARBALL" | tar -x
elif python3 -c 'import zstandard' 2> /dev/null; then
    python3 - "$TARBALL" <<'PY'
import sys, tarfile, zstandard
with open(sys.argv[1], "rb") as f, zstandard.ZstdDecompressor().stream_reader(f) as z:
    tarfile.open(fileobj=z, mode="r|").extractall(".")
PY
else
    echo "unpacking $TARBALL needs zstd, or python3 with zstandard (pip install zstandard)" >&2
    exit 1
fi
echo "$LEAN_SHA256" > "$STAMP"
rm -f "$TARBALL"
echo "fetched Lean $LEAN_VERSION ($LEAN_SHA256): $("$DIR/bin/lean" --version)"
