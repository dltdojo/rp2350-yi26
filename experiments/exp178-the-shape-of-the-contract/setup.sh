#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# exp178 setup — fetch the engine this experiment is about.
#
# OpenSK is somebody else's tree and stays visible as one: it is cloned here,
# never vendored, and `upstream/` is in this experiment's .gitignore. Nothing
# under it is committed to this repository. What is committed is this script,
# the commit it pins, and the adapter written against it.
#
# The pin is a commit and not a tag on purpose. Upstream's tags are `ctap2.0`,
# `last_tock` and `hybrid-pqc`; none of them names the CTAP 2.1 tree that the
# `develop` branch carries, so a tag would pin the wrong thing.
#
#   ./setup.sh          clone at the pinned commit, or verify an existing clone

set -eu
cd "$(dirname "${BASH_SOURCE[0]}")"

UPSTREAM_URL="https://github.com/google/OpenSK"
UPSTREAM_SHA="b3b16fb3af12bd8249b9e2a6b4b5869d9036ccda"
DIR="upstream/OpenSK"

if [[ -d "$DIR/.git" ]]; then
    have="$(git -C "$DIR" rev-parse HEAD)"
    if [[ "$have" == "$UPSTREAM_SHA" ]]; then
        echo "already at the pinned commit: $UPSTREAM_SHA"
        exit 0
    fi
    echo "clone is at $have, pinning to $UPSTREAM_SHA"
    git -C "$DIR" fetch --depth 1 origin "$UPSTREAM_SHA"
    git -C "$DIR" checkout --detach "$UPSTREAM_SHA"
    exit 0
fi

mkdir -p upstream
# A shallow fetch of one commit: this needs ~11 MB, not the whole history.
git init --quiet "$DIR"
git -C "$DIR" remote add origin "$UPSTREAM_URL"
git -C "$DIR" fetch --quiet --depth 1 origin "$UPSTREAM_SHA"
git -C "$DIR" checkout --quiet --detach "$UPSTREAM_SHA"
echo "cloned $UPSTREAM_URL at $UPSTREAM_SHA"
