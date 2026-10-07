#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# tools/pioasm setup — build Raspberry Pi's PIO assembler, once.
#
# pioasm is the reference for what a PIO program's bytes are: an experiment
# commits its program as bytes, and its check.sh assembles the .pio source
# with this and compares, word for word. Nothing here simulates PIO.
#
# Pinned by tag AND by commit, the way tools/lean pins by sha256: the
# pico-sdk at 2.3.1, only tools/pioasm checked out, built with cmake and the
# host's C++ compiler. Fetched and built here, never committed (.gitignore).
#
#   ./setup.sh          fetch and build, or say what is already there

set -eu
cd "$(dirname "${BASH_SOURCE[0]}")"

SDK_TAG="2.3.1"
SDK_COMMIT="079c6f39023649b154152db30f1d781e884879bc"
SRC="pico-sdk-$SDK_TAG"
BIN="pioasm-$SDK_TAG/pioasm"
STAMP="pioasm-$SDK_TAG/.commit"

if [[ -x "$BIN" && "$(cat "$STAMP" 2>/dev/null)" == "$SDK_COMMIT" ]]; then
    echo "already have pioasm from pico-sdk $SDK_TAG ($SDK_COMMIT)"
    exit 0
fi

rm -rf "$SRC" "pioasm-$SDK_TAG"
git -c advice.detachedHead=false clone -q --depth 1 --branch "$SDK_TAG" --filter=blob:none --sparse \
    https://github.com/raspberrypi/pico-sdk "$SRC"
got="$(git -C "$SRC" rev-parse HEAD)"
if [[ "$got" != "$SDK_COMMIT" ]]; then
    echo "pico-sdk $SDK_TAG is $got, not the pinned $SDK_COMMIT — refusing to use it" >&2
    exit 1
fi
git -C "$SRC" sparse-checkout set tools/pioasm
cmake -S "$SRC/tools/pioasm" -B "pioasm-$SDK_TAG" -DCMAKE_BUILD_TYPE=Release -DPIOASM_VERSION_STRING="$SDK_TAG" > /dev/null
cmake --build "pioasm-$SDK_TAG" -j "$(nproc)" > /dev/null
echo "$SDK_COMMIT" > "$STAMP"
rm -rf "$SRC"
echo "built pioasm from pico-sdk $SDK_TAG ($SDK_COMMIT): $BIN"
