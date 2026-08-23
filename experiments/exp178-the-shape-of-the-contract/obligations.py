#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Counts what OpenSK's `Env` demands, and what it hands over for free.

The numbers in this experiment's README are the point of it, so they are
counted from upstream's source at the pinned commit rather than typed in. A
method whose signature ends in `;` is one somebody has to write. One that ends
in `{` is one upstream already wrote, and the ratio between them is the whole
finding: a contract can be wide and still be cheap, if the wide part comes with
answers.

Counted by reading braces, not by grep: several of these signatures run to four
lines, and an earlier version of this file counted only the ones that fitted on
one — which undercounted `UserPresence` by exactly the method that matters.

Feature-gated methods are counted as gated rather than required, because a
build that does not turn the feature on does not have to write them, and this
experiment's build turns almost nothing on.
"""

import json
import os
import re
import sys

TRAITS = {
    "Rng": "rng.rs",
    "UserPresence": "user_presence.rs",
    "Clock": "clock.rs",
    "HidConnection": "connection.rs",
    "Persist": "persist.rs",
    "KeyStore": "key_store.rs",
    "Customization": "customization.rs",
    "Crypto": "crypto/mod.rs",
    "Env": "../env/mod.rs",
}


def strip_comments(src):
    """Doc comments are prose, and prose contains the words `fn` and `type`.

    An earlier version of this file counted `Customization` as having an
    associated type because one of its comments says "the type of". Comments go
    before anything else is decided.
    """
    return re.sub(r"//[^\n]*", "", src)


def scan(path, name):
    """Walk one trait body and sort its items into required, provided, gated."""
    src = strip_comments(open(path).read())
    start = src.index(f"pub trait {name}")
    at = src.index("{", start) + 1
    depth, out = 1, {"required": [], "provided": [], "gated": [], "types": []}
    gated = False
    while at < len(src) and depth > 0:
        ch = src[at]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            at += 1
            continue
        if depth == 1:
            m = re.match(r"#\[cfg\(feature[^\]]*\]", src[at:])
            if m:
                gated = True
                at += m.end()
                continue
            m = re.match(r"(fn|type)\s+(\w+)", src[at:])
            if m:
                kind, item = m.group(1), m.group(2)
                # Walk to whichever comes first at this depth: `;` (a demand)
                # or `{` (an answer upstream already wrote).
                j, d = at + m.end(), 0
                while j < len(src):
                    c = src[j]
                    # `->` is not a closing bracket, and reading it as one put
                    # `[u8; 32]`'s semicolon outside every bracket and turned
                    # the one method `Rng` provides into one it demands.
                    if c == "-" and src[j + 1:j + 2] == ">":
                        j += 2
                        continue
                    if c in "(<[":
                        d += 1
                    elif c in ")>]":
                        d -= 1
                    elif d <= 0 and c == ";":
                        bucket = "types" if kind == "type" else ("gated" if gated else "required")
                        break
                    elif d <= 0 and c == "{":
                        bucket = "gated" if gated else "provided"
                        break
                    j += 1
                out[bucket].append(item)
                gated = False
                at = j
                continue
        at += 1
    return out


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    api = os.path.join(here, "upstream", "OpenSK", "libraries", "opensk", "src", "api")
    result = {}
    for name, rel in TRAITS.items():
        result[name] = scan(os.path.join(api, rel), name)

    total_req = sum(len(v["required"]) for v in result.values())
    total_prov = sum(len(v["provided"]) for v in result.values())
    total_types = sum(len(v["types"]) for v in result.values())

    print(f"{'trait':<16}{'must write':>11}{'free':>7}{'gated':>7}{'types':>7}")
    for name, v in result.items():
        print(f"{name:<16}{len(v['required']):>11}{len(v['provided']):>7}"
              f"{len(v['gated']):>7}{len(v['types']):>7}")
    print(f"{'total':<16}{total_req:>11}{total_prov:>7}"
          f"{sum(len(v['gated']) for v in result.values()):>7}{total_types:>7}")

    result["totals"] = {"required": total_req, "provided": total_prov,
                        "associated_types": total_types}
    json.dump(result, open(os.path.join(here, "obligations.json"), "w"), indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
