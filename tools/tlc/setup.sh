#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# tools/tlc setup — fetch the model checker, once.
#
# TLC ships as one jar. It is fetched, never committed (it is in this
# directory's .gitignore), and pinned by release AND by sha256: the release tag
# alone is not enough, because a tag on that project has been seen serving a
# nightly build under a release's name. v1.7.4 is TLC 2.19 of 08 August 2024.
#
#   ./setup.sh          fetch and verify, or verify what is already there

set -eu
cd "$(dirname "${BASH_SOURCE[0]}")"

TLA_RELEASE="v1.7.4"
TLA_SHA256="936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88"
JAR="tla2tools.jar"

verify() { [[ "$(sha256sum "$JAR" | cut -d' ' -f1)" == "$TLA_SHA256" ]]; }

if [[ -f "$JAR" ]] && verify; then
    echo "already have tla2tools.jar $TLA_RELEASE ($TLA_SHA256)"
    exit 0
fi

curl -sSfL --max-time 120 -o "$JAR.part" \
    "https://github.com/tlaplus/tlaplus/releases/download/$TLA_RELEASE/tla2tools.jar"
mv "$JAR.part" "$JAR"
if ! verify; then
    echo "tla2tools.jar does not match the pinned sha256 — refusing to use it" >&2
    rm -f "$JAR"
    exit 1
fi
echo "fetched tla2tools.jar $TLA_RELEASE ($TLA_SHA256)"
